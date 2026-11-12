#lang racket/base

;; Workbench updater tests (racket/autarx/app-update.rkt): the release
;; identity, the pure derivations the host flows depend on (install flavor,
;; AppImage/MSI asset mapping), and the phase machine's offline behavior —
;; the signed-manifest trust chain itself is covered in update-test.rkt (the
;; CLI shares it through rivet/distribution). The network error path runs
;; against a closed local port, never the live feed.

(require rackunit
         racket/file
         racket/string
         (only-in rivet/distribution
                  select-update
                  update-artifact
                  update-candidate?
                  update-manifest)
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

(test-case "release identity is coherent with the repo manifest"
  (check-equal? (a:workbench-version) rktd-version)
  (check-equal? (a:manifest-url)
                (string-append a:default-update-base-url
                               "/update-app-manifest.json"))
  (check-equal?
   (parameterize ([a:current-update-base-url "https://dl.example/autarx/"])
     (a:manifest-url))
   "https://dl.example/autarx/update-app-manifest.json"))

;; Packaged-layout resolution: the 0.5.0 release runner exited the packaged
;; app at launch because the load-time version lookup missed the macOS
;; bundle layout (Contents/Resources/app) — pin the candidates and the
;; per-directory read so a packaged regression trips here, not in rivet's
;; launch smoke.
(test-case "app-info candidates cover every packaged layout"
  (define base (make-temporary-file "autarx-layout-~a" 'directory))
  (define exe-dir (build-path base "Autarx.app" "Contents" "MacOS"))
  (define dirs (a:app-info-candidate-dirs exe-dir))
  (check-equal? (length dirs) 4)
  ;; macOS bundle: Contents/MacOS → Contents/Resources/app
  (check-not-false
   (member (simplify-path (build-path base "Autarx.app" "Contents" "Resources" "app"))
           dirs)
   "macOS bundle layout missing")
  ;; stage root: exe beside app/
  (check-not-false
   (member (build-path exe-dir "app")
           dirs)
   "stage-root layout missing")
  (delete-directory/files base))

(test-case "app-info version reads the packaged bundle layout"
  (define base (make-temporary-file "autarx-bundle-~a" 'directory))
  (define app-dir (build-path base "Contents" "Resources" "app"))
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
               (a:flavor-for-exe-path 'windows
                                      "C:\\Program Files\\Autarx\\" #f)
               "msi")
              (check-equal?
               (a:flavor-for-exe-path 'windows
                                      "C:\\Program Files (x86)\\Autarx\\" #f)
               ;; the (x86) tree must not match the Program Files prefix
               "zip")
              (check-equal?
               (a:flavor-for-exe-path 'windows "C:\\Tools\\Autarx\\" #f)
               "zip"))))))))

(test-case "linux install flavor separates appimage, package and tarball"
  (check-equal? (a:flavor-for-exe-path 'linux "/opt/autarx/RivetHost" #f)
                "package")
  (check-equal? (a:flavor-for-exe-path 'linux "/usr/bin/" #f) "package")
  (check-equal? (a:flavor-for-exe-path 'linux "/home/u/autarx/RivetHost" #f)
                "tarball")
  (check-equal?
   (a:flavor-for-exe-path 'linux "/home/u/autarx/RivetHost"
                          "/mounts/Autarx-0.5.0-x86_64.AppImage")
   "appimage"))

(test-case "appimage asset name maps feed arch and drops the -app suffix"
  (check-equal?
   (a:appimage-asset-name "autarx-0.5.0-linux-x64-app.tar.gz" 'x64)
   "autarx-0.5.0-linux-x86_64.AppImage")
  (check-equal?
   (a:appimage-asset-name "autarx-0.5.0-linux-arm64-app.tar.gz" 'arm64)
   "autarx-0.5.0-linux-aarch64.AppImage")
  (check-exn exn:fail?
             (lambda ()
               (a:appimage-asset-name "autarx-0.5.0-linux-x64.tar.gz" 'x64)))
  (check-exn exn:fail?
             (lambda ()
               (a:appimage-asset-name
                "autarx-0.5.0-linux-x86_64-app.tar.gz" 'x64))))

(test-case "msi asset urls derive from the -app zip feed entry"
  (define-values (msi sidecar)
    (a:msi-artifact-urls
     "https://github.com/turinglambdaai/autarx/releases/download/v0.5.0/autarx-0.5.0-windows-x64-app.zip"))
  (check-equal?
   msi
   "https://github.com/turinglambdaai/autarx/releases/download/v0.5.0/autarx-0.5.0-windows-x64.msi")
  (check-equal?
   sidecar
   "https://github.com/turinglambdaai/autarx/releases/download/v0.5.0/autarx-0.5.0-windows-x64.msi.sha256")
  (check-exn exn:fail?
             (lambda ()
               (a:msi-artifact-urls
                "https://dl.example/autarx-0.5.0-windows-x64.zip"))))

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

(test-case "make-updater-config selects the feed's component-less artifact"
  ;; Regression: the two live config sites kept the nine-argument
  ;; updater-config shape after rivet #271 grew the struct a required
  ;; component field, while the published feed's artifacts carry no
  ;; component at all (#f) — on a new rivet the check died with an arity
  ;; error that the check's own handler masked as a generic error state.
  ;; The shim must fall back to #f, never 'app, or selection would
  ;; silently never match the real feed. Build the config exactly the way
  ;; the live check builds it and select against a manifest shaped like
  ;; the published feed.
  (define (feed-shape-artifact platform architecture url sha256 size installer arguments)
    (with-handlers
        ([exn:fail:contract:arity?
          (lambda (_)
            (apply update-artifact
                   (append (list platform architecture url sha256 size installer arguments)
                           (list #f))))])
      (update-artifact platform architecture url sha256 size installer arguments)))
  (define manifest
    (update-manifest "site.jrtx.autarx.Autarx" "9.9.9" 99 'stable
                     "2026-11-01T00:00:00Z" "0.0.0" #f #t 100
                     (list (feed-shape-artifact (a:platform-symbol)
                                                (a:architecture-symbol)
                                                "https://downloads.example.com/autarx-9.9.9-linux-x64-app.tar.gz"
                                                (make-string 64 #\a)
                                                123456 'targz '()))))
  (check-true (update-candidate? (select-update (a:make-updater-config) manifest))
              "the shipped config must select the feed's component-less artifact"))
