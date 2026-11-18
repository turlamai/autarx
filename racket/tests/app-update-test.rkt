#lang racket/base

;; Workbench updater tests (racket/autarx/app-update.rkt): the release
;; identity, the pure derivations the host flow depends on (install flavor,
;; packaged layouts), and the managed check/download surface — the signed
;; wrapper machinery lives in rivet/distribution (the CLI shares it) and is
;; exercised here through an injected verified manifest, so the real
;; download worker, progress and verification still run.

(require rackunit
         net/base64
         racket/file
         racket/path
         racket/string
         racket/tcp
         (only-in rivet/distribution
                  select-update
                  sha256-file/hex
                  update-artifact
                  update-artifact-installer
                  update-candidate?
                  update-candidate-artifact
                  update-manifest
                  updater-config)
         ;; Transport injection for the managed worker: tests only.
         (submod (lib "rivet/distribution/managed-updater.rkt") test-support)
         (prefix-in a: "../autarx/app-update.rkt"))

;; The repo manifest, resolved from this file's location (racket/tests/ →
;; two directories up) — raco test runs with an unrelated CWD.
(define rktd-version
  (hash-ref
   (call-with-input-file
       (simplify-path
        (build-path (variable-reference->module-source
                     (#%variable-reference))
                    'up 'up 'up "rivet.rktd"))
     read)
   'version))

(define (wait-until ready? who [timeout-ms 15000])
  (let loop ([deadline (+ (current-inexact-milliseconds) timeout-ms)])
    (cond
      [(ready?) (void)]
      [(> (current-inexact-milliseconds) deadline)
       (fail (string-append "timed out waiting for " who))]
      [else (sleep 0.05) (loop deadline)])))

(test-case "release identity is coherent with the repo manifest"
  (check-equal? (a:workbench-version) rktd-version)
  (check-equal? (a:manifest-url)
                (string-append a:default-update-base-url
                               "/update-app-manifest.json"))
  (check-equal?
   (parameterize ([a:current-update-base-url "https://dl.example/autarx/"])
     (a:manifest-url))
   "https://dl.example/autarx/update-app-manifest.json"))

;; Packaged-layout resolution: pin the candidates and the per-directory
;; read so a packaged regression trips here, not in rivet's launch smoke.
(test-case "app-info candidates cover every packaged layout"
  (define base (make-temporary-file "autarx-layout-~a" 'directory))
  (define exe-dir (build-path base "stage"))
  (define dirs (a:app-info-candidate-dirs exe-dir))
  (check-equal? (length dirs) 3)
  ;; stage root: exe beside app/
  (check-not-false
   (member (build-path exe-dir "app")
           dirs)
   "stage-root layout missing")
  ;; CLI-style launcher layouts: beside the exe and its parent
  (check-not-false (member exe-dir dirs) "exe-dir candidate missing")
  (check-not-false
   (member (simplify-path (build-path exe-dir 'up)) dirs)
   "parent-dir candidate missing")
  (delete-directory/files base))

(test-case "app-info version reads the packaged stage layout"
  (define base (make-temporary-file "autarx-bundle-~a" 'directory))
  (define app-dir (build-path base "app"))
  (make-directory* app-dir)
  (call-with-output-file (build-path app-dir "rivet-app-info.rktd")
    #:exists 'truncate
    (lambda (out) (write (hasheq 'version "9.9.8") out)))
  (check-equal? (a:app-info-version-in app-dir) "9.9.8")
  (check-false (a:app-info-version-in base))
  (delete-directory/files base))

;; Env fiddling must not leak across cases. Racket has no unsetenv, so #f
;; puts the empty string — every derivation in app-update.rkt treats an
;; empty value as "not set".
(define (with-env var value thunk)
  (define saved (getenv var))
  (dynamic-wind
    (lambda () (putenv var (or value "")))
    thunk
    (lambda () (if saved (putenv var saved) (putenv var "")))))

(test-case "windows install flavor separates msi from portable zip"
  (with-env "ProgramFiles" "C:\\Program Files"
    (lambda ()
      (with-env "ProgramFiles(x86)" #f
        (lambda ()
          (with-env "ProgramW6432" #f
            (lambda ()
              (check-equal?
               (a:flavor-for-exe-path "C:\\Program Files\\Autarx\\")
               "msi")
              (check-equal?
               (a:flavor-for-exe-path "C:\\Program Files (x86)\\Autarx\\")
               ;; the (x86) tree must not match the Program Files prefix
               "zip")
              (check-equal?
               (a:flavor-for-exe-path "C:\\Tools\\Autarx\\")
               "zip"))))))))

;; ---- managed check/download -------------------------------------------------

;; The shipped updater's install kind follows the running install shape
;; (msi under Program Files, portable elsewhere), so the test feed carries
;; every installer for this platform/arch — the same bytes under each
;; entry. Real feeds carry one per install shape.
(define (feed-manifest url sha size [installers '(zip msi)])
  (update-manifest
   "site.jrtx.autarx.Autarx" "9.9.9" 99 'stable
   "2026-11-01T00:00:00Z" "0.0.0" #f #t 100
   (for/list ([installer (in-list installers)])
     (update-artifact (a:platform-symbol)
                      (a:architecture-symbol)
                      url sha size installer '()
                      ;; rivet #271: component-less feed.
                      #f))))

(define (check-with-manifest! manifest)
  (parameterize ([a:current-update-base-url "https://dl.example/autarx"]
                 [current-managed-fetch-manifest
                  (lambda (_url _key
                          #:key-id [_key-id #f]
                          #:trusted-keys [_trusted-keys '()]
                          #:maximum-bytes [_maximum-bytes (* 1024 1024)])
                    manifest)])
    (a:perform-check!)))

;; A one-shot HTTP server for the artifact bytes.
(define (serve-bytes! payload)
  (define listener (tcp-listen 0 8 #f "127.0.0.1"))
  (define port-number
    (cadr (call-with-values (lambda () (tcp-addresses listener #t)) list)))
  (define server
    (thread
     (lambda ()
       (let loop ()
         (define-values (in out) (tcp-accept listener))
         (thread
          (lambda ()
            (with-handlers ([exn:fail? void])
              (let drain ()
                (define line (read-line in 'any))
                (unless (or (eof-object? line) (equal? line "")
                            (equal? line "\r"))
                  (drain)))
              (fprintf out
                       "HTTP/1.0 200 OK\r\nContent-Length: ~a\r\n\r\n"
                       (bytes-length payload))
              (write-bytes payload out)
              (close-output-port out)
              (close-input-port in))))
         (loop)))))
  (values port-number
          (lambda () (kill-thread server) (tcp-close listener))))

(test-case "check against an unreachable feed reports the error phase"
  (a:reset-update-state!)
  (parameterize ([a:current-update-base-url "https://127.0.0.1:9/autarx"])
    (define result (a:perform-check!))
    (check-equal? (hash-ref result 'status) "error")
    (check-true (string? (hash-ref result 'message)))
    (check-equal? (hash-ref (a:update-state-snapshot) 'phase) "error")
    ;; a failed check leaves no candidate behind
    (check-exn exn:fail? (lambda () (a:start-download!)))))

(test-case "the state machine exposes the taskly phase shape"
  (a:reset-update-state!)
  (define s (a:update-state-snapshot))
  (check-equal? (hash-ref s 'phase) "idle")
  (check-equal? (hash-ref s 'percent) 0)
  (check-false (hash-ref s 'downloadedPath))
  (a:set-update-error! "boom")
  (define failed (a:update-state-snapshot))
  (check-equal? (hash-ref failed 'phase) "error")
  (check-equal? (hash-ref failed 'message) "boom")
  (a:reset-update-state!)
  (check-equal? (hash-ref (a:update-state-snapshot) 'phase) "idle"))

(test-case "the shipped updater selects the feed's component-less artifact"
  ;; Regression from the pre-managed config shim: the feed's artifacts carry
  ;; no component (#f); selecting with 'app answered up-to-date forever.
  (a:reset-update-state!)
  (check-equal? (hash-ref (check-with-manifest!
                           (feed-manifest
                            "https://downloads.example.com/autarx-9.9.9-windows-x64-app.zip"
                            (make-string 64 #\a) 123456))
                          'status)
                "available")
  (a:reset-update-state!))

(test-case "the managed download verifies and publishes the artifact"
  (define payload (make-bytes 200000 42))
  (define scratch (make-temporary-file "autarx-payload-~a"))
  (call-with-output-file scratch #:exists 'truncate
    (lambda (out) (write-bytes payload out)))
  (define sha (sha256-file/hex scratch))
  (delete-file scratch)
  (define-values (port-number stop-server!) (serve-bytes! payload))
  (dynamic-wind
    void
    (lambda ()
      (a:reset-update-state!)
      (check-equal?
       (hash-ref (check-with-manifest!
                  (feed-manifest
                   (format "http://127.0.0.1:~a/autarx-9.9.9-windows-x64-app.zip"
                           port-number)
                   sha (bytes-length payload)))
                 'status)
       "available")
      (a:start-download!)
      (wait-until (lambda ()
                    (equal? (hash-ref (a:update-state-snapshot) 'phase)
                            "downloaded"))
                  "the downloaded phase")
      (define downloaded (hash-ref (a:update-state-snapshot) 'downloadedPath))
      (check-true (and downloaded (file-exists? downloaded)))
      (check-equal? (sha256-file/hex downloaded) sha)
      (check-equal? (hash-ref (a:update-state-snapshot) 'percent) 100)
      (check-false (file-exists? (path-add-extension downloaded #".partial")))
      (when (file-exists? downloaded) (delete-file downloaded))
      (a:reset-update-state!))
    stop-server!))

;; The feed must keep offering the signed msi installer for Program Files
;; installs (the Windows host hands off to msiexec).
(test-case "the windows feed carries both portable and msi artifacts"
  (define manifest
    (update-manifest
     "site.jrtx.autarx.Autarx" "9.9.9" 99 'stable
     "2026-11-01T00:00:00Z" "0.0.0" #f #t 100
     (list (update-artifact 'windows 'x64
                            "https://downloads.example.com/autarx-9.9.9-windows-x64-app.zip"
                            (make-string 64 #\a) 10 'zip '() #f)
           (update-artifact 'windows 'x64
                            "https://downloads.example.com/autarx-9.9.9-windows-x64.msi"
                            (make-string 64 #\b) 20 'msi '() #f))))
  (define config
    (updater-config "site.jrtx.autarx.Autarx" "0.5.0" 'stable
                    'windows 'x64 #f "autarx-2026-10" 0 (* 512 1024 1024) #f))
  (check-equal?
   (update-artifact-installer
    (update-candidate-artifact
     (select-update config manifest #:install-kind 'msi)))
   'msi)
  (check-equal?
   (update-artifact-installer
    (update-candidate-artifact
     (select-update config manifest #:install-kind 'portable)))
   'zip))
