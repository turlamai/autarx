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
                  make-updater
                  updater-check!
                  updater-download!
                  updater-state
                  updater-cancel!
                  updater-wait
                  updater-candidate
                  base64-string->bytes
                  update-artifact-installer
                  update-artifact-size
                  update-candidate-artifact
                  update-candidate-manifest
                  update-manifest-build
                  update-manifest-published-at
                  update-manifest-version)
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
         destination-directory
         update-state-snapshot
         reset-update-state!
         set-update-error!
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

;; Downloads land under <temp>/autarx/updates — the CLI updater's state
;; directory (writable on every desktop target; portable installs under
;; Program Files are not).
(define (destination-directory)
  (build-path (find-system-path 'temp-dir) "autarx" "updates"))

;; ------------------------------------------------------------ update state

;; phase: idle | checking | downloading | downloaded | error
(define (idle-snapshot)
  (hasheq 'phase "idle"
          'percent 0
          'message #f
          'downloadedPath #f
          'availableVersion #f))

(define update-state (box (idle-snapshot)))
(define updater-box (box #f))

(define (state-set! key value)
  (set-box! update-state (hash-set (unbox update-state) key value)))

;; The managed phases include transport/selection outcomes the UI treats as
;; idle: `available` carries its signal in availableVersion, `up-to-date`
;; means there is nothing to do, and `cancelled` returns the controls to
;; idle. Anything else passes through unchanged.
(define (managed-state->product state)
  (define phase (hash-ref state 'phase "idle"))
  (define mapped-phase
    (case phase
      [("available" "up-to-date" "cancelled") "idle"]
      [else phase]))
  (define idle? (string=? mapped-phase "idle"))
  (hasheq 'phase mapped-phase
          'percent (if idle? 0 (hash-ref state 'percent 0))
          'message (let ([message (and (not idle?)
                                       (hash-ref state 'message #f))])
                     (if message message #f))
          'downloadedPath (let ([path (hash-ref state 'downloadedPath #f)])
                            (if path path #f))
          'availableVersion (let ([version (hash-ref state 'availableVersion #f)])
                              (if version version #f))))

(define (update-state-snapshot)
  (define product (unbox update-state))
  (define instance (unbox updater-box))
  (cond
    [(not instance) product]
    ;; A backend-side start failure (already running, no candidate)
    ;; outranks the managed snapshot until the next check clears it.
    [(equal? (hash-ref product 'phase "idle") "error") product]
    [else (managed-state->product (updater-state instance))]))

(define (reset-update-state!)
  ;; Dropping an instance while its worker runs would orphan the download;
  ;; land it on the terminal cancelled phase first.
  (define instance (unbox updater-box))
  (when (and instance (equal? (hash-ref (updater-state instance) 'phase)
                              "downloading"))
    (updater-cancel! instance)
    (updater-wait instance 5.0))
  (set-box! updater-box #f)
  (set-box! update-state (idle-snapshot)))

;; Pre-spawn download failures (already running, no candidate) surface
;; through the state instead of an RPC error, so host UIs have a single
;; failure channel.
(define (set-update-error! message)
  (state-set! 'phase "error")
  (state-set! 'message message))

;; ---------- install kind ----------

;; The installed flavor selects which manifest artifact this install may
;; apply. MSI installs under Program Files take the signed .msi and hand off
;; to the host; AppImage processes take the signed .AppImage. Everything
;; else (portable zip, tarball, package-managed prefixes) keeps the
;; historical portable payload; package-managed installs never download.
(define (update-install-kind)
  (case (install-flavor)
    [("msi") 'msi]
    [("appimage") 'appimage]
    [else #f]))

;; ---------- managed updater ----------

;; The verified AppImage installs in place: chmod, then atomically rename
;; over the running image. The host re-execs it on consent.
(define (install-appimage! verified self)
  ;; The replaced image must stay executable: rename carries the temp file's
  ;; modes, so set them explicitly before the swap. The setter takes integer
  ;; bits (the vector form is a contract violation on Windows, where POSIX
  ;; modes do not exist) — the swap is only ever reached under APPIMAGE.
  (unless (eq? (system-type 'os) 'windows)
    (file-or-directory-permissions verified #o755))
  (rename-file-or-directory verified self #t)
  self)

(define (make-autarx-updater)
  ;; Set by the destination callback for an AppImage install and consumed
  ;; by the after-download hook in the same instance.
  (define appimage-self-box (box #f))
  (make-updater
   #:application-id app-identifier
   #:current-version (workbench-version)
   #:channel app-channel
   #:platform (platform-symbol)
   #:architecture (architecture-symbol)
   #:install-kind (update-install-kind)
   ;; The feed's artifacts carry no component discriminator (rivet #271).
   #:component #f
   ;; DER bytes: the managed updater decodes them lazily during the check.
   #:public-key (base64-string->bytes update-public-key-b64)
   #:key-id update-key-id
   #:manifest-url (manifest-url)
   #:data-directory (destination-directory)
   #:destination
   (lambda (candidate)
     (cond
       [(equal? (install-flavor) "appimage")
        (define self-string (getenv "APPIMAGE"))
        (unless (and self-string (non-empty-string? self-string))
          (error 'start-download
                 "APPIMAGE is not set; not running as an AppImage"))
        (define self (string->path self-string))
        (set-box! appimage-self-box self)
        ;; Reserve a unique name, then remove the file: a failed
        ;; verification must not strand an empty staging file beside the
        ;; running image (rivet's managed download cleans only its .partial).
        (define staged
          (make-temporary-file "autarx-update-~a.AppImage"
                               #f
                               (path-only self)))
        (delete-file staged)
        staged]
       [else (destination-path candidate)]))
   #:after-download
   (lambda (verified candidate)
     (define self (unbox appimage-self-box))
     (if self
         (install-appimage! verified self)
         verified))
   #:rollout-bucket (rollout-bucket)
   #:maximum-download-bytes maximum-download-bytes))

;; ---------- check ----------

(define (download-running?)
  (define instance (unbox updater-box))
  (and instance
       (equal? (hash-ref (updater-state instance) 'phase) "downloading")))

;; Returns a plain hasheq describing the outcome; backend.rkt maps it onto
;; the typed UpdateCheck record. Throttling is the host's job. Never raises.
(define (perform-check!)
  (cond
    ;; Keep the running transfer (and its instance) instead of orphaning
    ;; the worker; the UI retries the check once the download ends.
    [(download-running?)
     (hasheq 'status "error" 'message "an update download is already running")]
    [else
     (reset-update-state!)
     (with-handlers
         ([exn:fail?
           (lambda (e)
             (state-set! 'phase "error")
             (state-set! 'message (exn-message e))
             (hasheq 'status "error" 'message (exn-message e)))])
       (define instance (make-autarx-updater))
       (set-box! updater-box instance)
       (updater-check! instance))]))

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

;; Runs on a backend worker thread; the host follows progress via the
;; update_state RPC. Failures surface through the phase.
(define (start-download!)
  (define instance (unbox updater-box))
  (unless (and instance (updater-candidate instance))
    (error 'start-download! "no update is available; run a check first"))
  (updater-download! instance))
