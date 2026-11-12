#lang racket/base

;; Online update support for the Autarx workbench backend, built on
;; rivet/distribution — the taskly updater pattern: the backend verifies and
;; downloads the signed update artifact, the native host owns installation.
;; A check fetches the workbench feed (update-app-manifest.json — the same
;; signed wrapper the macOS host's RivetUpdate client reads); the download
;; runs on a background thread with progress published to a state box the
;; hosts poll through the `update_state` RPC (RVT1 events are thread-local,
;; so a background thread cannot emit them directly).
;;
;; Feed artifacts per platform (scripts/make-update-manifest.sh): macos
;; app.zip (consumed by the Swift host, not this module), windows
;; autarx-<v>-windows-x64-app.zip (the host swaps the install directory),
;; linux autarx-<v>-linux-<arch>-app.tar.gz (hand-off install). The CLI
;; keeps its own feed (update.rkt / update-manifest.json) — two feeds, one
;; format and one key, because the manifest schema admits one artifact per
;; platform × architecture × installer and the CLI zips are separate
;; payloads.
;;
;; Install flavors mirror the taskly split. Windows: a copy under the
;; Program Files tree is an MSI install — the updater downloads the sibling
;; .msi release asset (checksummed against its .sha256 sidecar) and the host
;; hands off to a passive msiexec upgrade; portable zip installs swap in
;; place. Linux: $APPIMAGE selects the AppImage leg (the sibling .AppImage
;; asset replaces the running image, checksummed against its sidecar);
;; deb/rpm prefixes never download (the host shows the package-manager
;; guidance); everything else is the portable tarball, downloaded for the
;; host's open-folder hand-off.
;;
;; The 4-hour silent-check throttle lives in the hosts (no backend setting
;; store); this module only persists the sticky rollout bucket, shared with
;; the CLI updater through update.rkt's state file.

;; Note on crypto factories: rivet/distribution pins the provider set to
;; libcrypto at module load and deliberately avoids crypto/all — factory
;; FFIs load at import time and the gmp factory kills embedded runtimes on
;; hosts without libgmp. This module runs inside the embedded CS runtime,
;; so it must not require crypto/all either (tests may, they are headless).

(require crypto
         net/url
         (only-in rivet/distribution
                  fetch-update-manifest
                  select-update
                  update-artifact-installer
                  update-artifact-size
                  update-artifact-url
                  update-candidate-artifact
                  update-candidate-manifest
                  update-manifest-build
                  update-manifest-published-at
                  update-manifest-version
                  updater-config
                  updater-config-maximum-download-bytes
                  verify-update-artifact!
                  base64-string->bytes
                  sha256-file/hex)
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         "update.rkt")

(provide workbench-version
         app-info-candidate-dirs
         app-info-version-in
         update-key-id
         update-public-key-b64
         default-update-base-url
         current-update-base-url
         manifest-url
         maximum-download-bytes
         platform-symbol
         architecture-symbol
         install-flavor
         flavor-for-exe-path
         appimage-asset-name
         msi-artifact-urls
         destination-directory
         update-state-snapshot
         reset-update-state!
         set-update-error!
         make-updater-config
         perform-check!
         start-download!)

;; ------------------------------------------------------------ identity

(define app-identifier "site.jrtx.autarx.Autarx")
(define app-channel 'stable)
(define app-display-name "Autarx")

(define update-key-id "autarx-2026-10")

;; SubjectPublicKeyInfo DER, base64 — the same keypair the macOS host
;; embeds in raw form (UpdateService.swift) and the CLI updater authenticates
;; with (update.rkt). The private half lives outside the repository and never
;; ships (UPDATE_ED25519_PRIVATE_KEY_B64 CI secret; scripts/update-keys.sh).
(define update-public-key-b64
  "MCowBQYDK2VwAyEAIjm2Iqrres1BbLnx5DQCvZtbbKb4jBKRpUbGSQ9FWxM=")

;; The workbench feed. The release pipeline pins artifact URLs to the
;; concrete tag; the manifest itself is always fetched from the moving
;; "latest" location. Tests parameterize this at an unreachable local URL
;; instead of touching the network.
(define default-update-base-url
  "https://github.com/turlamai/autarx/releases/latest/download")

(define current-update-base-url (make-parameter #f))

(define maximum-download-bytes (* 800 1024 1024))

(define (manifest-url)
  (string-append
   (string-trim (or (current-update-base-url) default-update-base-url)
                "/" #:right? #t)
   "/update-app-manifest.json"))

(define (embedded-public-key)
  (datum->pk-key (base64-string->bytes update-public-key-b64)
                 'SubjectPublicKeyInfo))

;; Release identity, single-sourced on rivet.rktd. Staged apps carry a
;; rivet-app-info.rktd under app/ beside the executable (rivet's
;; write-app-info!); CLI-style layouts carry it beside the launcher or its
;; parent; source checkouts read the repo manifest three directories above
;; this file. No version literal here — a build that finds neither file is a
;; packaging bug and must fail loudly (scripts/check-release-version.sh
;; guards the source).
;; Candidate directories that carry rivet-app-info.rktd, relative to the
;; running executable's directory: stage-root layouts (exe beside app/),
;; CLI-style launcher layouts (beside the exe or its parent, bin/-style),
;; and the macOS bundle (Contents/MacOS → Contents/Resources/app). Pure so
;; the packaged-layout resolution is testable without a bundle.
(define (app-info-candidate-dirs exe-dir)
  (list exe-dir
        (simplify-path (build-path exe-dir 'up))
        (build-path exe-dir "app")
        (simplify-path (build-path exe-dir 'up "Resources" "app"))))

(define (app-info-version-in dir)
  (define info (build-path dir "rivet-app-info.rktd"))
  (and (directory-exists? dir)
       (file-exists? info)
       (call-with-input-file info
         (lambda (in)
           (define doc (read in))
           (define v (if (hash? doc) (hash-ref doc 'version #f) #f))
           (and (string? v) v)))))

(define (version-from-app-info)
  (define run-file (find-system-path 'run-file))
  (define exe-dir (if (path? run-file) (path-only run-file) #f))
  (define candidate-dirs
    (if exe-dir (app-info-candidate-dirs exe-dir) (list)))
  (for/or ([dir (in-list candidate-dirs)])
    (app-info-version-in dir)))

(define (version-from-manifest)
  (define src
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (variable-reference->module-source (#%variable-reference))))
  (and (path? src)
       (file-exists? src)
       (let ([manifest (with-handlers ([exn:fail? (lambda (_) #f)])
                         (simplify-path (build-path src 'up 'up 'up "rivet.rktd")))])
         (and manifest
              (file-exists? manifest)
              (call-with-input-file manifest
                (lambda (in)
                  (define doc (read in))
                  (define v (if (hash? doc) (hash-ref doc 'version #f) #f))
                  (and (string? v) v)))))))

;; Evaluated lazily (a procedure, not a load-time define): a packaged
;; environment that carries neither file must fail the check_updates RPC,
;; not abort the embedded runtime at module load and take the host down
;; (the 0.5.0 release-runner lesson — the load-time define exited the
;; packaged app during rivet's launch smoke).
(define (workbench-version)
  (or (version-from-app-info)
      (version-from-manifest)
      (error 'autarx-update
             "cannot determine version: no rivet-app-info.rktd beside the executable and no source rivet.rktd")))

;; ------------------------------------------------------------ platform identity

;; rivet release tooling emits these exact symbols into update manifests.
(define (platform-symbol)
  (case (system-type 'os)
    [(macosx) 'macos]
    [(windows) 'windows]
    [else 'linux]))

(define (architecture-symbol)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

;; Pure so tests can pin the derivation: `exe` is the running executable's
;; directory string, `appimage-env` the $APPIMAGE value (or #f). The flavor
;; decides which download leg start-download! runs — the host independently
;; computes the same shape for its UX copy, and the two must agree. Windows
;; paths stay raw strings (no filesystem normalization) so the derivation is
;; testable on every OS; the separator-aware prefix check keeps Program
;; Files (x86) from matching the Program Files prefix.
(define (normalize-dir s)
  (string-downcase (string-trim s #px"[/\\\\]" #:right? #t)))

(define (flavor-for-exe-path os exe appimage-env)
  (case os
    [(windows)
     (define (under-program-files variable)
       (define prefix (normalize-dir (or (getenv variable) "")))
       (cond
         [(string=? prefix "") #f]
         [else
          (define directory (normalize-dir exe))
          (or (string=? directory prefix)
              (string-prefix? directory (string-append prefix "\\")))]))
     (if (or (under-program-files "ProgramFiles")
             (under-program-files "ProgramFiles(x86)")
             (under-program-files "ProgramW6432"))
         "msi"
         "zip")]
    [else
     (cond
       [(and appimage-env (not (string=? appimage-env ""))) "appimage"]
       [(or (string-prefix? exe "/opt/autarx/")
            (string-prefix? exe "/usr/"))
        "package"]
       [else "tarball"])]))

(define (executable-directory-string)
  (define run-file (find-system-path 'run-file))
  (if (path? run-file)
      (path->string (simplify-path (path-only run-file)))
      (path->string (current-directory))))

(define (install-flavor)
  (flavor-for-exe-path (system-type 'os)
                       (executable-directory-string)
                       (getenv "APPIMAGE")))

;; The AppImage release asset name for a feed tar.gz: feed files carry the
;; -app suffix and the feed arch spelling (x64|arm64) while AppImage builds
;; use the platform arch spelling (x86_64|aarch64):
;;   autarx-0.5.0-linux-x64-app.tar.gz → autarx-0.5.0-linux-x86_64.AppImage
(define (appimage-asset-name tar-gz-filename architecture)
  (unless (string-suffix? tar-gz-filename "-app.tar.gz")
    (error 'appimage-asset-name "not an autarx app tar.gz filename: ~a"
           tar-gz-filename))
  (define stem
    (substring tar-gz-filename 0
               (- (string-length tar-gz-filename)
                  (string-length "-app.tar.gz"))))
  (define feed-arch (string-append "-" (symbol->string architecture)))
  (unless (string-suffix? stem feed-arch)
    (error 'appimage-asset-name
           "feed filename does not end in ~a: ~a" feed-arch stem))
  (define appimage-arch
    (case architecture [(arm64) "aarch64"] [else "x86_64"]))
  (string-append (substring stem 0 (- (string-length stem)
                                      (string-length feed-arch)))
                 "-"
                 appimage-arch
                 ".AppImage"))

;; The MSI release asset + checksum sidecar for a feed zip URL. The feed
;; entry carries the -app suffix (update-payload internals); the human
;; installer keeps the plain family name:
;;   …/autarx-0.5.0-windows-x64-app.zip → …/autarx-0.5.0-windows-x64.msi
(define (msi-artifact-urls zip-url)
  (unless (string-suffix? zip-url "-app.zip")
    (error 'msi-artifact-urls
           "cannot derive an msi url from a non-app zip feed entry"))
  (define stem
    (substring zip-url 0 (- (string-length zip-url)
                            (string-length "-app.zip"))))
  (values (string-append stem ".msi")
          (string-append stem ".msi.sha256")))

;; Downloads land under <temp>/autarx/updates — the CLI updater's state
;; directory (writable on every desktop target; portable installs under
;; Program Files are not).
(define (destination-directory)
  (build-path (find-system-path 'temp-dir) "autarx" "updates"))

;; ------------------------------------------------------------ update state

;; phase: idle | checking | downloading | downloaded | error
(define update-state
  (box (hasheq 'phase "idle"
               'percent 0
               'message #f
               'downloadedPath #f
               'availableVersion #f)))

(define candidate-box (box #f))
(define worker-thread-box (box #f))

(define (state-set! key value)
  (set-box! update-state (hash-set (unbox update-state) key value)))

(define (update-state-snapshot)
  (unbox update-state))

(define (reset-update-state!)
  (set-box! candidate-box #f)
  (set-box! update-state
            (hasheq 'phase "idle"
                    'percent 0
                    'message #f
                    'downloadedPath #f
                    'availableVersion #f)))

;; Pre-spawn download failures (already running, no candidate) surface
;; through the state instead of an RPC error, so host UIs have a single
;; failure channel.
(define (set-update-error! message)
  (state-set! 'phase "error")
  (state-set! 'message message))

;; Download watchdog bounds: no byte progress for the stall limit, or wall
;; clock past the total limit, breaks the worker (it cleans up the .partial
;; and reports phase=error itself) so the host always reaches a terminal
;; state instead of resting on a frozen percent.
(define download-stall-limit-seconds 120)
(define download-total-limit-seconds (* 30 60))
(define last-progress-seconds (box 0))

;; ---------- check ----------

;; rivet moved updater-config to 10 fields (component) after the v0.11.0
;; pin; the feed's artifacts carry no component at all (#f) and
;; select-update matches config component against artifact component, so
;; construct through this shim: plain on old rivets, #f component on new —
;; never 'app (racket/tests/app-update-test.rkt pins it against a
;; feed-shaped manifest).
(define (make-updater-config)
  (define args
    (list app-identifier
          (workbench-version)
          app-channel
          (platform-symbol)
          (architecture-symbol)
          (embedded-public-key)
          update-key-id
          (rollout-bucket)
          maximum-download-bytes))
  (with-handlers
      ([exn:fail:contract:arity?
        (lambda (_)
          (apply updater-config (append args (list #f))))])
    (apply updater-config args)))

;; Returns a plain hasheq describing the outcome; backend.rkt maps it onto
;; the typed UpdateCheck record. Throttling is the host's job. Never raises.
(define (perform-check!)
  (reset-update-state!)
  (state-set! 'phase "checking")
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (state-set! 'phase "error")
          (state-set! 'message (exn-message e))
          (hasheq 'status "error" 'message (exn-message e)))])
    (define manifest
      (fetch-update-manifest (manifest-url)
                             (embedded-public-key)
                             #:key-id update-key-id))
    (define config (make-updater-config))
    (define candidate (select-update config manifest))
    (cond
      [candidate
       (set-box! candidate-box candidate)
       (define artifact (update-candidate-artifact candidate))
       (state-set! 'phase "idle")
       (state-set! 'availableVersion
                   (update-manifest-version
                    (update-candidate-manifest candidate)))
       (hasheq 'status "available"
               'currentVersion (workbench-version)
               'availableVersion
               (update-manifest-version
                (update-candidate-manifest candidate))
               'build (update-manifest-build
                       (update-candidate-manifest candidate))
               'publishedAt
               (update-manifest-published-at
                (update-candidate-manifest candidate))
               'installer (symbol->string (update-artifact-installer artifact))
               'sizeBytes (update-artifact-size artifact))]
      [else
       (state-set! 'phase "idle")
       (state-set! 'availableVersion #f)
       (hasheq 'status "up-to-date" 'currentVersion (workbench-version))])))

;; ---------- download ----------

(define (destination-path candidate)
  (define version
    (update-manifest-version (update-candidate-manifest candidate)))
  (define extension
    (case (install-flavor)
      [(msi) ".msi"]
      [(appimage) ".AppImage"]
      [else (if (eq? (platform-symbol) 'windows) ".zip" ".tar.gz")]))
  (build-path (destination-directory)
              (string-append app-display-name "-" version extension)))

;; Copy with progress; same limits as rivet's download-update but publishes
;; integer percent changes to the state box while streaming. Release asset
;; URLs redirect to the CDN, so follow redirections like rivet's own
;; downloader does (the 302-into-an-empty-body trap, rivet#153).
(define (copy-with-progress! in out total)
  (define buffer (make-bytes 65536))
  (let loop ([done 0] [last-percent -1])
    (define count (read-bytes-avail! buffer in))
    (cond
      [(eof-object? count) done]
      [else
       ;; Every successful read feeds the watchdog's stall clock (not just
       ;; integer percent changes, so a slow link never false-trips it).
       (set-box! last-progress-seconds (current-seconds))
       (write-bytes buffer out 0 count)
       (define next (+ done count))
       (define percent
         (if (> total 0)
             (min 100 (quotient (* next 100) total))
             0))
       (when (> percent last-percent)
         (state-set! 'percent percent))
       (loop next percent)])))

;; Manifest-verified flow (zip / tar.gz): rivet's download-update enforces
;; the signed size and SHA-256 before the file is trusted and follows the
;; release-CDN redirections; this wrapper adds the progress states the UI
;; polls. Runs on the worker thread.
(define (download-with-progress! config candidate destination)
  (define artifact (update-candidate-artifact candidate))
  (define total (update-artifact-size artifact))
  (when (> total (updater-config-maximum-download-bytes config))
    (error 'download-update "signed artifact size exceeds the download limit"))
  (make-parent-directory* destination)
  (define temporary (path-add-extension destination #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise e))])
    (define in
      (get-pure-port (string->url (update-artifact-url artifact))
                     '("User-Agent: Autarx-Updater/1")
                     #:redirections 10))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file temporary
          #:exists 'truncate/replace
          #:mode 'binary
          (lambda (out) (copy-with-progress! in out total))))
      (lambda () (close-input-port in)))
    ;; size + SHA-256 against the signed manifest before the file is trusted
    (verify-update-artifact! candidate temporary)
    (rename-file-or-directory temporary destination #t)
    destination))

;; Sidecar downloads (.msi / .AppImage) come from the same CDN without a
;; signed manifest, so the response head is the only total available: parse
;; Content-Length for the progress percent (0 → indeterminate) and hand the
;; body port to the copy loop. Connection: close keeps the copy ending at
;; EOF, exactly like the manifest-verified flow.
(define (open-download-with-total! url)
  (define in (get-impure-port (string->url url)
                              '("User-Agent: Autarx-Updater/1"
                                "Connection: close")))
  (let loop ([total 0])
    (define line (read-line in 'return-linefeed))
    (cond
      [(eof-object? line) (values in 0)]
      [(non-empty-string? (string-trim line))
       (define match
         (regexp-match #px"(?i:^content-length:\\s*(\\d+))" line))
       (loop (if match (string->number (second match)) total))]
      [else (values in total)])))

;; sha256sum format: "<hex>  <filename>"; the first token is the digest.
(define (fetch-sidecar-sha256! url)
  (define in (get-pure-port (string->url url)
                            '("User-Agent: Autarx-Updater/1")
                            #:redirections 10))
  (dynamic-wind
    void
    (lambda ()
      (define digest
        (let ([body (string-trim (port->string in))])
          (if (string=? body "") "" (first (string-split body)))))
      (unless (regexp-match? #px"^[0-9a-fA-F]{64}$" digest)
        (error 'start-download "checksum sidecar has an unexpected shape"))
      (string-downcase digest))
    (lambda () (close-input-port in))))

(define (download-with-sidecar! url destination)
  (define sidecar-url (string-append url ".sha256"))
  (define expected (fetch-sidecar-sha256! sidecar-url))
  (make-parent-directory* destination)
  (define temporary (path-add-extension destination #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise e))])
    (define-values (in total) (open-download-with-total! url))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file temporary
          #:exists 'truncate/replace
          #:mode 'binary
          (lambda (out) (copy-with-progress! in out total))))
      (lambda () (close-input-port in)))
    (define actual (string-downcase (sha256-file/hex temporary)))
    (unless (string=? actual expected)
      (raise-arguments-error 'start-download
                             "downloaded artifact does not match its checksum sidecar"
                             "expected" expected
                             "actual" actual))
    destination))

(define (download-msi-with-progress! candidate)
  (define-values (msi-url _sidecar-url)
    (msi-artifact-urls (update-artifact-url
                        (update-candidate-artifact candidate))))
  (download-with-sidecar! msi-url (destination-path candidate)))

;; AppImage: the download lands NEXT TO the running image ($APPIMAGE, set by
;; the AppImage runtime) so the final rename stays on one device, then
;; replaces it after the sidecar checksum verifies; the host re-execs the
;; replaced image on consent.
(define (download-appimage-with-progress! candidate)
  (define self (getenv "APPIMAGE"))
  (unless (and self (non-empty-string? self))
    (error 'start-download "APPIMAGE is not set; not running as an AppImage"))
  (define url (update-artifact-url (update-candidate-artifact candidate)))
  (define filename
    (last (string-split (car (string-split url "?")) "/")))
  (define appimage-name
    (appimage-asset-name filename (architecture-symbol)))
  (define appimage-url (string-replace url filename appimage-name))
  (define temporary
    (make-temporary-file "autarx-update-~a.AppImage" #f (path-only self)))
  (define destination (download-with-sidecar! appimage-url temporary))
  ;; The replaced image must stay executable: rename carries the temp file's
  ;; modes, so set them explicitly before the swap. The setter takes integer
  ;; bits (the vector form is a contract violation on Windows, where POSIX
  ;; modes do not exist) — the swap itself is only ever reached under
  ;; APPIMAGE, i.e. never on Windows.
  (unless (eq? (system-type 'os) 'windows)
    (file-or-directory-permissions destination #o755))
  (rename-file-or-directory destination self #t)
  self)

;; Runs on a backend worker thread; the host follows progress via the
;; update_state RPC. Never raises: failures surface through the phase.
(define (start-download!)
  (define worker (unbox worker-thread-box))
  (when (and worker (thread-running? worker))
    (error 'start-download! "an update download is already running"))
  (define candidate (unbox candidate-box))
  (unless candidate
    (error 'start-download! "no update is available; run a check first"))
  (state-set! 'phase "downloading")
  (state-set! 'percent 0)
  (state-set! 'message #f)
  (define config (make-updater-config))
  (set-box! last-progress-seconds (current-seconds))
  (define worker-thread
    (thread
     (lambda ()
       (define destination (destination-path candidate))
       ;; The watchdog breaks a stalled worker; exn:break is not an
       ;; exn:fail, so it needs its own arm — either way the .partial
       ;; file is removed and the phase lands on error (never
       ;; mid-flight).
       (with-handlers
           ([(lambda (e) (or (exn:fail? e) (exn:break? e)))
             (lambda (e)
               (define temporary
                 (path-add-extension destination #".partial"))
               (when (file-exists? temporary) (delete-file temporary))
               (state-set! 'phase "error")
               (state-set! 'message
                           (if (exn:break? e)
                               "update download stalled or timed out"
                               (exn-message e))))])
         (define path
           (case (install-flavor)
             [(msi) (download-msi-with-progress! candidate)]
             [(appimage) (download-appimage-with-progress! candidate)]
             [else (download-with-progress! config candidate destination)]))
         (state-set! 'phase "downloaded")
         (state-set! 'percent 100)
         (state-set! 'downloadedPath
                     (if (path? path) (path->string path) path))))))
  (set-box! worker-thread-box worker-thread)
  ;; Watchdog: exits once the worker finishes on its own; otherwise a stall
  ;; (no byte progress) or the total wall-clock limit breaks the worker so
  ;; phase never rests on "downloading" indefinitely.
  (define download-started (current-seconds))
  (thread
   (lambda ()
     (let loop ()
       (cond
         [(sync/timeout download-stall-limit-seconds
                        (thread-dead-evt worker-thread))
          (void)]
         [(> (- (current-seconds) (unbox last-progress-seconds))
             download-stall-limit-seconds)
          (break-thread worker-thread)]
         [(> (- (current-seconds) download-started)
             download-total-limit-seconds)
          (break-thread worker-thread)]
         [else (loop)]))))
  (void))
