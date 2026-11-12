#lang racket/base

;; Online update support for the autarx CLI, built on rivet/distribution —
;; the family pattern (taskly/brainfuel): the updater fetches and verifies
;; the Ed25519-signed channel manifest, selects the artifact for this
;; platform, and downloads it under size + SHA-256 enforcement from the
;; signed manifest. The CLI-specific install leg (unzip → locate the marker
;; executable → in-place file swap with `<name>.autarx-update.old` backups)
;; stays here.
;;
;; The feed is the family signed-wrapper format (schema + base64 payload +
;; Ed25519 signature block) at update-manifest.json — the same file name the
;; retired checksum feed used, now authenticated before a byte of it is
;; parsed (shared/spec/UPDATE.md). CLI builds up to 0.2.0 read that file as
;; a plain {version, assets} JSON document; against the signed wrapper they
;; report a failed check instead of an update and need a one-off manual
;; install to cross over.
;;
;; Timeouts: rivet's fetch-update-manifest / download-update bound the
;; response in bytes but not in time — net/url ports have no read deadline,
;; so a connection that stalls without RST/FIN would park the CLI forever.
;; Both network legs run on a supervised worker thread that a watchdog
;; breaks on the stall limit (no byte progress) or the total wall-clock
;; limit (the taskly updater's download watchdog, adapted to a synchronous
;; CLI instead of a background thread + UI state box — there is no RPC
;; consumer here to poll progress).
;;
;; Note on crypto factories: rivet/distribution pins the provider set to
;; libcrypto at module load and deliberately avoids crypto/all — factory
;; FFIs load at import time and the gmp factory kills embedded runtimes on
;; hosts without libgmp. This module runs inside the embedded CS runtime,
;; so it must not require crypto/all either (tests may, they are headless).

(require crypto
         net/base64
         rivet/distribution
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system)

(provide app-identifier
         app-channel
         app-display-name
         update-key-id
         update-public-key-b64
         default-update-base-url
         current-update-base-url
         current-update-manifest-url
         maximum-download-bytes
         platform-symbol
         architecture-symbol
         detect-update-platform
         installer-extension
         manifest-url
         rollout-bucket
         set-update-state-dir-override!
         check-for-update!
         download-candidate!
         destination-path
         extract-verified
         apply-payload
         cleanup-stale-backups)

;; Release identity duplicated from rivet.rktd. The version is deliberately
;; NOT embedded: autarx single-sources it from rivet-app-info.rktd /
;; rivet.rktd (cli.rkt's autarx-version; scripts/check-release-version.sh
;; guards the source) and passes it into check-for-update!.
(define app-identifier "site.jrtx.autarx.Autarx")
(define app-channel 'stable)
(define app-display-name "Autarx")

(define update-key-id "autarx-2026-10")

;; SubjectPublicKeyInfo DER, base64 — the same keypair the macOS host
;; embeds in raw form (UpdateService.swift) and the release pipeline signs
;; BOTH feeds with (the UPDATE_ED25519_PRIVATE_KEY_B64 GitHub secret;
;; generate: scripts/update-keys.sh). The private half lives outside the
;; repository and never ships. Rotate by shipping a build that trusts the
;; next key before releases stop being signed with this one.
(define update-public-key-b64
  "MCowBQYDK2VwAyEAIjm2Iqrres1BbLnx5DQCvZtbbKb4jBKRpUbGSQ9FWxM=")

;; Where the updater looks for the signed manifest. The workbench polls the
;; sibling update-app-manifest.json — two feeds, one format and one key,
;; because the manifest schema admits one artifact per platform ×
;; architecture × installer and macOS carries both the app zip (host) and
;; this portable zip (shared/spec/UPDATE.md). The release pipeline pins
;; artifact URLs to the concrete tag; the manifest itself is always fetched
;; from the moving "latest" location. Tests parameterize this at an
;; unreachable local URL instead of touching the network.
(define default-update-base-url
  "https://github.com/turlamai/autarx/releases/latest/download")

(define current-update-base-url (make-parameter #f))
;; Full-URL override (--feed) taking precedence over the base join.
(define current-update-manifest-url (make-parameter #f))

(define maximum-download-bytes (* 800 1024 1024))

;; ---------- public key ----------

(define (embedded-public-key)
  (datum->pk-key (base64-string->bytes update-public-key-b64)
                 'SubjectPublicKeyInfo))

;; ---------- platform identity ----------

;; rivet release tooling emits these exact symbols into update manifests
(define (platform-symbol)
  (case (system-type 'os)
    [(macosx) 'macos]
    [(windows) 'windows]
    [else 'linux]))

(define (architecture-symbol)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

;; The CLI-facing "<platform>-<architecture>" spelling of this host (kept
;; for --platform parsing and human output; the release feed names its zip
;; files exactly this way).
(define (detect-update-platform)
  (string-append (symbol->string (platform-symbol))
                 "-"
                 (symbol->string (architecture-symbol))))

;; build-cli.sh ships the portable payload as a zip on every platform, so
;; the feed's artifacts are all installer 'zip.
(define (installer-extension) ".zip")

(define (manifest-url)
  (or (current-update-manifest-url)
      (string-append
       (string-trim (or (current-update-base-url) default-update-base-url)
                    "/" #:right? #t)
       "/update-manifest.json")))

;; ---------- watchdog bounds ----------

;; net/url ports have no read deadline, so both network legs are supervised:
;; no tick for the stall limit, or wall clock past the total limit, breaks
;; the worker (exn:break ends the blocked port read) and the caller gets a
;; clean failure instead of a hung process. The manifest cap is
;; fetch-update-manifest's 1 MiB default, so its deadline is simply 60 s.
(define manifest-deadline-seconds 60)
(define download-stall-limit-seconds 120)
(define download-total-limit-seconds (* 30 60))

;; Run THUNK (receiving a `touch` procedure that refreshes the stall clock)
;; on a worker thread under a watchdog. Returns the thunk's value; a
;; timeout or worker failure raises. The download leg passes `touch` as the
;; downloader's #:on-progress so a slow-but-alive link never false-trips
;; the stall limit; the manifest fetch has no progress surface and ignores
;; it (its deadline is the stall limit).
(define (call-under-watchdog! who stall-limit-seconds total-limit-seconds thunk)
  (define last-tick (box (current-seconds)))
  (define outcome (box #f))
  (define timed-out? (box #f))
  (define worker
    (thread
     (lambda ()
       (with-handlers ([(lambda (e) #t)
                        (lambda (e) (set-box! outcome (cons 'raised e)))])
         (set-box! outcome
                   (cons 'returned
                         (thunk (lambda ()
                                  (set-box! last-tick (current-seconds))))))))))
  (define started (current-seconds))
  (thread
   (lambda ()
     (let loop ()
       (cond
         [(sync/timeout stall-limit-seconds (thread-dead-evt worker)) (void)]
         [(or (> (- (current-seconds) (unbox last-tick)) stall-limit-seconds)
              (> (- (current-seconds) started) total-limit-seconds))
          (set-box! timed-out? #t)
          (break-thread worker)]
         [else (loop)]))))
  ;; The watchdog breaks the worker at the limits; wait a little past them
  ;; so the break lands before this call gives up on the worker.
  (unless (sync/timeout (+ total-limit-seconds 30) worker)
    (error who "update transfer outlived its watchdog budget"))
  (define record (unbox outcome))
  (cond
    [(and record (eq? (car record) 'returned)) (cdr record)]
    [(unbox timed-out?)
     (error who "update transfer timed out (stall or wall-clock limit)")]
    [(and record (eq? (car record) 'raised)) (raise (cdr record))]
    [else (error who "update worker failed without a result")]))

;; ---------- updater state (rollout bucket) ----------

;; Exactly these integer keys may exist in updater-state.json — the
;; brainfuel whitelist pattern, CLI-sized. The file lives under <temp>/autarx:
;; the CLI has no data dir of its own, temp is writable on every desktop
;; target (portable installs under Program Files are not), and it keeps
;; source checkouts clean. Stickiness is best-effort: the release rollout
;; is 100 today, so the bucket gates nothing until a staged rollout ships.
(define updater-state-keys '(rollout-bucket))

(define state-dir-override (box #f))

;; Test seam: redirect the state file away from the real temp dir.
(define (set-update-state-dir-override! dir)
  (set-box! state-dir-override dir))

(define (updater-state-path)
  (build-path (or (unbox state-dir-override)
                  (build-path (find-system-path 'temp-dir) "autarx"))
              "updater-state.json"))

(define (read-updater-state)
  (define path (updater-state-path))
  (if (file-exists? path)
      (with-handlers ([exn:fail? (lambda (_) (hasheq))])
        (define doc (with-input-from-file path read))
        (if (hash? doc) doc (hasheq)))
      (hasheq)))

(define (write-updater-state! doc)
  ;; Whitelist on write: unknown keys are dropped, so a corrupt or
  ;; hand-edited file can never grow product data into the updater store.
  ;; Best-effort persistence: an unwritable location keeps the bucket
  ;; in memory (it re-draws next run) instead of failing the update.
  (define clean
    (for/hasheq ([key (in-list updater-state-keys)])
      (define value (hash-ref doc key #f))
      (if (and value (exact-integer? value) (<= 0 value 99))
          (values key value)
          (values key #f))))
  (define path (updater-state-path))
  (define dir (path-only path))
  (with-handlers ([exn:fail:filesystem? (lambda (_) (void))])
    (when dir (make-parent-directory* dir))
    (call-with-output-file path
      #:exists 'truncate/replace
      (lambda (out) (write clean out)))))

;; Stable random 0..99 assigned on first check so staged rollouts are
;; sticky per installation. Persisted in updater-state.json;
;; crypto-random-bytes, not `random`: racket/base's PRNG has a fixed seed,
;; which would put every fresh install in the same lockstep bucket.
(define (rollout-bucket)
  (define existing (hash-ref (read-updater-state) 'rollout-bucket #f))
  (if (and existing (exact-integer? existing) (<= 0 existing 99))
      existing
      (let ([bucket
             (modulo (integer-bytes->integer (crypto-random-bytes 4) #t #t)
                     100)])
        (write-updater-state! (hash-set (read-updater-state)
                                        'rollout-bucket
                                        bucket))
        bucket)))

;; ---------- check ----------

;; Fetches the signed manifest, verifies its Ed25519 signature and key id,
;; and selects the artifact for this platform — or reports why not. Returns
;; a plain hasheq; never raises (the CLI maps status onto output and exit
;; codes). CURRENT-VERSION comes from the caller: the version is
;; single-sourced in rivet.rktd / rivet-app-info.rktd and must not be
;; duplicated here. The selected candidate is stashed for download-candidate!.
(define (check-for-update! current-version
                           #:platform [platform #f]
                           #:architecture [architecture #f])
  (with-handlers
      ([exn:fail?
        (lambda (e) (hasheq 'status "error" 'message (exn-message e)))])
    (define manifest
      (call-under-watchdog!
       'check-for-update!
       manifest-deadline-seconds
       manifest-deadline-seconds
       (lambda (_touch)
         (fetch-update-manifest (manifest-url)
                                (embedded-public-key)
                                #:key-id update-key-id))))
    (define config
      (updater-config app-identifier
                      current-version
                      app-channel
                      (or platform (platform-symbol))
                      (or architecture (architecture-symbol))
                      (embedded-public-key)
                      update-key-id
                      (rollout-bucket)
                      maximum-download-bytes
                      ;; rivet #271: component #f = the plain whole-app
                      ;; artifact (legacy manifests carry no component) —
                      ;; the same argument download-candidate! passes
                      #f))
    (define candidate (select-update config manifest))
    (set-box! candidate-box candidate)
    (set-box! current-version-box current-version)
    (if candidate
        (hasheq 'status "available"
                'currentVersion current-version
                'availableVersion
                (update-manifest-version
                 (update-candidate-manifest candidate))
                'build (update-manifest-build
                        (update-candidate-manifest candidate))
                'publishedAt
                (update-manifest-published-at
                 (update-candidate-manifest candidate))
                'sha256 (update-artifact-sha256
                         (update-candidate-artifact candidate))
                'sizeBytes (update-artifact-size
                            (update-candidate-artifact candidate)))
        (hasheq 'status "up-to-date"
                'currentVersion current-version
                'latestVersion (update-manifest-version manifest)))))

(define candidate-box (box #f))
;; The version the running candidate was selected against — stashed by
;; check-for-update! because updater-config needs it again at download
;; time and the CLI has no reason to pass it around twice.
(define current-version-box (box #f))

;; ---------- download ----------

(define (destination-path destination-directory candidate)
  (build-path destination-directory
              "updates"
              (string-append app-display-name "-"
                             (update-manifest-version
                              (update-candidate-manifest candidate))
                             (installer-extension))))

;; Downloads the checked candidate into <destination-directory>/updates and
;; returns the verified path. rivet's download-update enforces the signed
;; size and SHA-256 before the file is trusted and follows the release-CDN
;; redirections itself; this wrapper adds the time bounds the CLI needs.
;; Runs under the watchdog; raises on failure (the caller owns the message).
(define (download-candidate! destination-directory)
  (define candidate (unbox candidate-box))
  (unless candidate
    (error 'download-candidate! "no update is available; run a check first"))
  (define current-version (unbox current-version-box))
  (unless current-version
    (error 'download-candidate! "no checked version; run a check first"))
  (define destination (destination-path destination-directory candidate))
  (call-under-watchdog!
   'download-candidate!
   download-stall-limit-seconds
   download-total-limit-seconds
   (lambda (touch)
     (download-update
      (updater-config app-identifier
                      current-version
                      app-channel
                      (platform-symbol)
                      (architecture-symbol)
                      (embedded-public-key)
                      update-key-id
                      (rollout-bucket)
                      maximum-download-bytes
                      ;; rivet #271: component #f = the plain whole-app
                      ;; artifact (legacy manifests carry no component).
                      #f)
      candidate
      destination
      #:on-progress (lambda (_bytes) (touch)))))
  destination)

;; ---------- installer (the CLI-owned leg) ----------

(define (strip-trailing-slash s)
  (if (and (> (string-length s) 1)
           (memq (string-ref s (- (string-length s) 1)) '(#\/ #\\)))
      (substring s 0 (- (string-length s) 1))
      s))

(define (regular-file? p)
  (eq? (file-or-directory-type p) 'file))

;; Re-verifies the downloaded zip against the feed checksum before anything
;; is expanded. rivet's download-update already enforced size + SHA-256 at
;; download time; this second check closes the window between the verified
;; rename and extraction (and keeps the offline installer path honest).
;; Returns the payload root — the directory containing marker-file-name.
(define (extract-verified zip-path expected-sha256 marker-file-name)
  (define actual (string-downcase (sha256-file/hex zip-path)))
  (unless (string-ci=? actual expected-sha256)
    (error 'extract-verified
           "checksum mismatch: expected ~a, got ~a" expected-sha256 actual))
  (define extract-dir
    (make-temporary-file "autarx-update-~a" 'directory))
  (define unzipped? (unzip-archive zip-path extract-dir))
  (unless unzipped?
    (delete-directory/files extract-dir)
    (error 'extract-verified "cannot extract update package"))
  (define marker (find-marker extract-dir marker-file-name))
  (unless marker
    (delete-directory/files extract-dir)
    (error 'extract-verified
           "update package does not contain ~a" marker-file-name))
  (strip-trailing-slash
   (path->string (simplify-path (path-only marker)))))

;; Extraction is the one subprocess the installer still needs (Windows
;; end-user machines ship PowerShell, not unzip); the download transport
;; itself is pure Racket now.
(define (unzip-archive zip-path dest)
  (case (system-type 'os)
    [(windows)
     (system*/exit-code (find-executable-path "powershell") "-NoProfile"
                        "-Command"
                        (format "Expand-Archive -LiteralPath '~a' -DestinationPath '~a' -Force"
                                (path->string zip-path) dest))]
    [else
     (system*/exit-code (find-executable-path "unzip")
                        "-q" zip-path "-d" dest)]))

(define (find-marker dir name)
  (for/or ([p (in-list (find-files (lambda (_) #t) dir))])
    (and (string=? (path->string (file-name-from-path p)) name) p)))

;; Swaps the payload over the installation; returns the file count.
(define (apply-payload payload-root-str app-directory)
  (define payload-root (simplify-path (string->path payload-root-str)))
  (cleanup-stale-backups app-directory)
  (define replaced
    (for/list ([source (in-list (find-files regular-file? payload-root))])
      (define relative
        (path->string (find-relative-path payload-root source)))
      (define target (build-path app-directory relative))
      (make-parent-directory* target)
      (when (file-exists? target)
        (define backup (string->path (string-append (path->string target)
                                                    ".autarx-update.old")))
        (when (file-exists? backup) (delete-file backup))
        (rename-file-or-directory target backup))
      (copy-file source target #:exists-ok? #t)
      relative))
  (delete-directory/files payload-root)
  (length replaced))

;; stale .old files that cannot be deleted stay for the next run
(define (cleanup-stale-backups app-directory)
  (for/sum ([stale (in-list (find-files
                             (lambda (p)
                               (and (regular-file? p)
                                    (string-suffix?
                                     (path->string p)
                                     ".autarx-update.old")))
                             app-directory))])
    (with-handlers ([exn:fail:filesystem? (lambda (_) 0)])
      (delete-file stale)
      1)))
