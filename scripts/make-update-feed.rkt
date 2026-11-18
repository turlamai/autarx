#lang racket/base

;; Compose and sign the CLI update feed (update-manifest.json) — the family
;; signed-wrapper format (rivet/distribution): the inner manifest travels
;; base64-encoded inside a JSON envelope, so the Ed25519 signature covers
;; the exact bytes every client verifies. Replaces the pre-0.3.1 plain
;; {version, assets} checksum feed: `autarx update` now authenticates the
;; feed before a byte of it is parsed, with the same key that signs the
;; workbench's update-app-manifest.json (sibling script
;; make-update-manifest.sh). CLI builds up to and including 0.4.0 read
;; the old checksum shape and report a failed check against the signed
;; feed — a one-off manual install moves them over (shared/spec/UPDATE.md).
;;
;; The workbench keeps its own feed because the manifest schema admits one
;; artifact per platform × architecture × installer, and the workbench app
;; zip and this portable CLI zip are separate update targets.
;;
;; Usage: racket scripts/make-update-feed.rkt <tag> <dist-dir> <base-url>
;;   <tag>       release tag, e.g. v0.4.0 (must match rivet.rktd's version)
;;   <dist-dir>  directory with the CLI release zips
;;               (autarx-<ver>-windows-x64.zip — the only shipped platform)
;;   <base-url>  artifact URL base, i.e. the concrete release download URL
;;
;; Signing key — DER OneAsymmetricKey, either of:
;;   UPDATE_ED25519_PRIVATE_KEY_B64 (the CI secret, base64) or
;;   UPDATE_KEY_PATH (a DER file; PEM needs the OpenSSL 3 conversion the
;;   sibling script performs). A release without a key FAILS here: an
;;   unauthenticated feed is the supply-chain gap this script retires.
;;
;; Requires racket with rivet linked (the release job installs the pinned
;; checkout).

(require net/base64
         racket/date
         racket/file
         racket/format
         racket/path
         racket/string
         rivet/distribution
         (only-in crypto pk-key->public-only-key))

(define key-id "autarx-2026-10")

(define tag (vector-ref (current-command-line-arguments) 0))
(define dist
  (path->complete-path (vector-ref (current-command-line-arguments) 1)))
(define base-url
  (string-trim (vector-ref (current-command-line-arguments) 2) "/" #:right? #t))

(define version
  (if (string-prefix? tag "v") (substring tag 1) tag))

;; The repo root — one directory above this script's source file (the same
;; module-source resolution cli.rkt uses; works for `racket scripts/…`,
;; which is the only supported invocation).
(define root
  (simplify-path
   (build-path
    (path-only
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (variable-reference->module-source (#%variable-reference))))
    'up)))
(define rktd (file->value (build-path root "rivet.rktd")))
(unless (string=? version (hash-ref rktd 'version))
  (error 'make-update-feed
         "tag ~a does not match rivet.rktd version '~a'"
         tag (hash-ref rktd 'version)))

;; DER private key from the CI secret or a key file; anything else fails
;; the release (no key, no feed — never an unauthenticated feed).
(define key-bytes
  (cond
    [(getenv "UPDATE_ED25519_PRIVATE_KEY_B64")
     => (lambda (b64) (base64-string->bytes (string-trim b64)))]
    [(getenv "UPDATE_KEY_PATH")
     => (lambda (path) (file->bytes path))]
    [else
     (error 'make-update-feed
            "no signing key: set UPDATE_ED25519_PRIVATE_KEY_B64 or UPDATE_KEY_PATH")]))

(define key-path (make-temporary-file "autarx-feed-key-~a.der"))
(call-with-output-file key-path #:exists 'truncate
  (lambda (out) (write-bytes key-bytes out)))

;; feed tokens ("windows-x64") split into the manifest's symbol pair
(define (split-platform token)
  (define parts (string-split token "-"))
  (values (string->symbol (car parts))
          (string->symbol (string-join (cdr parts) "-"))))

;; Windows-only product (issue #56): the CLI feed carries windows-x64
;; exclusively.
(define platform-regexp
  #px"autarx-[0-9][^-]*-(windows-x64)\\.zip$")

(define artifacts
  (for/list ([path (in-directory dist)]
             #:when (and (file-exists? path)
                         (regexp-match? platform-regexp
                                        (path->string path))))
    (define name (path->string (file-name-from-path path)))
    (define-values (platform architecture)
      (split-platform (cadr (regexp-match platform-regexp name))))
    (update-artifact platform architecture
                     (string-append base-url "/" name)
                     (sha256-file/hex path)
                     (file-size path)
                     'zip
                     '())))

(when (null? artifacts)
  (error 'make-update-feed "no autarx-*.zip artifacts found in ~a" dist))

;; Deterministic artifact order: same dist, same signed bytes.
(define sorted-artifacts
  (sort artifacts
        (lambda (a b)
          (string<? (format "~a/~a" (update-artifact-platform a)
                            (update-artifact-architecture a))
                    (format "~a/~a" (update-artifact-platform b)
                            (update-artifact-architecture b))))))

(define manifest
  (update-manifest
   (hash-ref rktd 'identifier)
   version
   (hash-ref rktd 'build)
   'stable
   ;; published-at: RFC 3339, second precision, UTC
   (let ([d (seconds->date (current-seconds) #f)])
     (format "~a-~a-~aT~a:~a:~aZ"
             (date-year d)
             (~r (date-month d) #:min-width 2 #:pad-string "0")
             (~r (date-day d) #:min-width 2 #:pad-string "0")
             (~r (date-hour d) #:min-width 2 #:pad-string "0")
             (~r (date-minute d) #:min-width 2 #:pad-string "0")
             (~r (date-second d) #:min-width 2 #:pad-string "0")))
   "0.0.0"
   #f
   #t
   100
   sorted-artifacts))

;; write-signed-manifest validates the struct against the manifest schema
;; before signing, so a malformed manifest fails the release instead of
;; shipping something every client would reject.
(define out-path (build-path dist "update-manifest.json"))
(call-with-output-file out-path
  #:exists 'truncate/replace
  (lambda (out)
    (write-signed-manifest manifest (read-ed25519-private-key key-path) key-id out)
    (newline out)))

;; Sign → verify round trip: a private key whose public half differs from
;; the one embedded in the clients fails the release here, not in a
;; customer's update check.
(verify-signed-manifest
 (open-input-file out-path)
 (pk-key->public-only-key (read-ed25519-private-key key-path))
 #:key-id key-id)

(printf "make-update-feed: ~a (~a signed artifacts, application ~a, key-id ~a)\n"
        out-path
        (length sorted-artifacts)
        (hash-ref rktd 'identifier)
        key-id)
(delete-file key-path)
