#lang racket/base

;; Updater tests — the offline trust chain and the CLI installer leg: craft
;; a manifest, sign it with a throwaway Ed25519 key, verify it, and select
;; updates the same way the live checker does; then the verified extraction
;; and the in-place swap with backups. (fetch-update-manifest only accepts
;; HTTPS, so the network half is exercised in production; the error path
;; runs against a closed local port.)

(require crypto
         crypto/all
         rackunit
         rivet/distribution
         racket/file
         racket/path
         racket/string
         file/zip
         (prefix-in u: "../autarx/update.rkt"))

(use-all-factories!)

(test-case "platform symbols are pinned to the shipped windows-x64 pair"
  ;; Windows-only product (issue #56): the identity is constant, not
  ;; host-derived — the feed carries windows-x64 exclusively
  (check-equal? (u:platform-symbol) 'windows)
  (check-equal? (u:architecture-symbol) 'x64)
  (check-equal? (u:detect-update-platform) "windows-x64"))

(test-case "the portable payload is a zip"
  (check-equal? (u:installer-extension) ".zip"))

(test-case "manifest url joins base and file name"
  (check-equal? (u:manifest-url)
                (string-append u:default-update-base-url
                               "/update-manifest.json"))
  (check-equal?
   (parameterize ([u:current-update-base-url "https://dl.example/autarx/"])
     (u:manifest-url))
   "https://dl.example/autarx/update-manifest.json")
  (check-equal?
   (parameterize ([u:current-update-base-url "https://dl.example/autarx"])
     (u:manifest-url))
   "https://dl.example/autarx/update-manifest.json")
  (check-equal?
   (parameterize ([u:current-update-manifest-url
                   "https://dl.example/autarx/signed-feed.json"])
     (u:manifest-url))
   "https://dl.example/autarx/signed-feed.json"))

(test-case "rollout bucket is sticky and persists to updater-state.json"
  (define state-dir (make-temporary-file "autarx-updater-home-~a" 'directory))
  (u:set-update-state-dir-override! state-dir)
  (check-true (exact-integer? (u:rollout-bucket)))
  (define first (u:rollout-bucket))
  (check-true (<= 0 first 99))
  ;; a second read returns the persisted bucket, not a fresh draw
  (check-equal? (u:rollout-bucket) first)
  (define doc
    (call-with-input-file (build-path state-dir "updater-state.json") read))
  (check-equal? (hash-ref doc 'rollout-bucket) first)
  (u:set-update-state-dir-override! #f))

(test-case "check against an unreachable feed reports the error status"
  (parameterize ([u:current-update-base-url "https://127.0.0.1:9/autarx"])
    (define result (u:check-for-update! "0.0.1"))
    (check-equal? (hash-ref result 'status) "error")
    (check-true (string? (hash-ref result 'message)))
    ;; a failed check leaves no candidate behind
    (check-exn exn:fail?
               (lambda ()
                 (u:download-candidate!
                  (make-temporary-file "upd-dl-~a" 'directory))))))

(test-case "the old checksum feed shape fails closed"
  ;; the pre-rivet feed was a plain {version, assets} document; the signed
  ;; wrapper parser must reject it before anything is trusted
  (check-exn exn:fail?
             (lambda ()
               (verify-signed-manifest
                (open-input-bytes
                 (string->bytes/utf-8
                  "{\"version\":\"9.9.9\",\"assets\":{}}"))
                (datum->pk-key (base64-string->bytes u:update-public-key-b64)
                               'SubjectPublicKeyInfo)))))

(test-case "signed manifest verifies and selects updates"
  ;; throwaway keypair: same DER formats the release pipeline uses
  (define priv (generate-private-key 'eddsa '((curve ed25519))))
  (define pub (datum->pk-key (pk-key->datum priv 'rkt-public) 'rkt-public))
  (define artifact-file (make-temporary-file "autarx-artifact-~a.zip"))
  (call-with-output-file artifact-file
    #:exists 'truncate
    (lambda (out) (write-bytes (make-bytes 128 3) out)))
  (define manifest
    (update-manifest
     u:app-identifier "9.9.9" 7 'stable
     "2026-10-09T00:00:00Z" "0.0.0" #f #t 100
     (list (update-artifact (u:platform-symbol) (u:architecture-symbol)
                            "https://dl.example/autarx/autarx-9.9.9-windows-x64.zip"
                            (sha256-file/hex artifact-file)
                            (file-size artifact-file)
                            'zip '()
                            ;; rivet #271: component #f = the plain whole-app
                            ;; artifact.
                            #f))))
  ;; write-signed-manifest refuses malformed manifests before signing
  (define wrapped (open-output-bytes))
  (write-signed-manifest manifest priv "autarx-test" wrapped)
  (define verified
    (verify-signed-manifest (open-input-bytes (get-output-bytes wrapped))
                            pub
                            #:key-id "autarx-test"))
  (check-equal? (update-manifest-version verified) "9.9.9")
  ;; a different key-id fails closed
  (check-exn exn:fail?
             (lambda ()
               (verify-signed-manifest
                (open-input-bytes (get-output-bytes wrapped))
                pub
                #:key-id "some-other-key")))
  ;; selection: newer version offered, same version and downgrades not
  (define (config-for version)
    (updater-config u:app-identifier version 'stable
                    (u:platform-symbol) (u:architecture-symbol)
                    pub "autarx-test" 42 1000000
                    ;; rivet #271: component #f = the plain whole-app artifact.
                    #f))
  (define candidate (select-update (config-for "0.1.0") verified))
  (check-true (update-candidate? candidate))
  (check-equal? (update-artifact-sha256 (update-candidate-artifact candidate))
                (string-downcase (sha256-file/hex artifact-file)))
  (check-false (select-update (config-for "9.9.9") verified))
  (check-false (select-update (config-for "10.0.0") verified))
  ;; another platform's artifact is not this host's candidate (the feed
  ;; never carries one — foreign platforms stopped shipping with issue #56)
  (define other-platform
    (update-manifest
     u:app-identifier "9.9.9" 7 'stable
     "2026-10-09T00:00:00Z" "0.0.0" #f #t 100
     (list (update-artifact
            'macos
            (u:architecture-symbol)
            "https://dl.example/autarx/autarx-9.9.9-other.zip"
            (sha256-file/hex artifact-file)
            (file-size artifact-file)
            'zip '()
            ;; rivet #271: component #f = the plain whole-app artifact.
            #f))))
  (check-false (select-update (config-for "0.1.0") other-platform))
  (delete-file artifact-file))

(test-case "embedded release identity is coherent"
  (check-equal? u:app-identifier "site.jrtx.autarx.Autarx")
  (check-equal? u:app-channel 'stable)
  (check-equal? u:app-display-name "Autarx")
  (check-equal? u:update-key-id "autarx-2026-10")
  ;; the embedded SPKI key is pinned by its raw 32-byte tail (the family
  ;; trust root; scripts/update-keys.sh derives every published form)
  (define key
    (datum->pk-key (base64-string->bytes u:update-public-key-b64)
                   'SubjectPublicKeyInfo))
  (check-true (pk-key? key))
  (check-equal?
   (bytes->base64-string
    (subbytes (pk-key->datum key 'SubjectPublicKeyInfo) 12))
   "Ijm2Iqrres1BbLnx5DQCvZtbbKb4jBKRpUbGSQ9FWxM="))

;; entries: list of (relative-path-string . content-bytes); laid out under
;; a temp directory then zipped relative to it (release-package shape)
(define (make-zip entries dest)
  (define base (make-temporary-file "upd-stage-~a" 'directory))
  (define staging (build-path base "cli"))
  (make-directory staging)
  (for ([e (in-list entries)])
    (define target (build-path staging (car e)))
    (make-directory* (path-only target))
    (call-with-output-file target #:exists 'replace
      (λ (out) (write-bytes (cdr e) out))))
  (parameterize ([current-directory base])
    (zip dest (string->path "cli")))
  (delete-directory/files base)
  dest)

(test-case "Extract_verified_accepts_matching_hash_and_locates_payload_root"
  (define base (make-temporary-file "upd-e2e-~a" 'directory))
  (define zip-path (build-path base "update.zip"))
  (make-zip (list (cons "cli/autarx.exe" #"new-binary")
                  (cons "cli/config.json" #"{}"))
            zip-path)
  (define sha (sha256-file/hex zip-path))
  (define root (u:extract-verified zip-path sha "autarx.exe"))
  (check-true (string-suffix? root "cli"))
  (check-equal? (file->bytes (build-path root "autarx.exe")) #"new-binary")
  (delete-directory/files base))

(test-case "Extract_verified_rejects_a_tampered_package_before_touching_anything"
  (define base (make-temporary-file "upd-tamper-~a" 'directory))
  (define zip-path (build-path base "update.zip"))
  (make-zip (list (cons "cli/autarx.exe" #"new-binary")) zip-path)
  (define fake-sha (make-string 64 #\0))
  (check-exn
   exn:fail?
   (λ () (u:extract-verified zip-path fake-sha "autarx.exe")))
  ;; rejection happens before anything is extracted: no leftovers
  (delete-directory/files base))

(test-case "Extract_verified_requires_the_marker_file"
  (define base (make-temporary-file "upd-marker-~a" 'directory))
  (define zip-path (build-path base "update.zip"))
  (make-zip (list (cons "other/readme.txt" #"hi")) zip-path)
  (define sha (sha256-file/hex zip-path))
  (check-exn exn:fail? (λ () (u:extract-verified zip-path sha "autarx.exe")))
  (delete-directory/files base))

(test-case "Apply_swaps_files_keeps_backups_and_cleans_stale_ones"
  (define base (make-temporary-file "upd-apply-~a" 'directory))
  (define zip-path (build-path base "update.zip"))
  (make-zip (list (cons "cli/autarx.exe" #"new-binary")
                  (cons "cli/config.json" #"{}"))
            zip-path)
  (define sha (sha256-file/hex zip-path))
  (define payload-root (u:extract-verified zip-path sha "autarx.exe"))
  (define app-dir (build-path base "app"))
  (make-directory app-dir)
  (call-with-output-file (build-path app-dir "autarx.exe") #:exists 'replace
    (λ (out) (display "old-binary" out)))
  (call-with-output-file (build-path app-dir "stale.autarx-update.old")
    #:exists 'replace
    (λ (out) (display "stale" out)))
  (define replaced (u:apply-payload payload-root app-dir))
  (check-equal? replaced 2)
  (check-equal? (file->bytes (build-path app-dir "autarx.exe")) #"new-binary")
  (check-equal? (file->bytes (build-path app-dir "config.json")) #"{}")
  (check-equal? (file->bytes (build-path app-dir "autarx.exe.autarx-update.old"))
                #"old-binary")
  (check-false (file-exists? (build-path app-dir "stale.autarx-update.old")))
  (delete-directory/files base))

(test-case "extracted_sha256_matches_known_vectors"
  ;; SHA-256 now comes from rivet/distribution (libcrypto), not the retired
  ;; pure-Racket implementation — pin the vectors anyway
  (define base (make-temporary-file "sha-~a" 'directory))
  (define (write+hash content)
    (define p (build-path base "in.bin"))
    (call-with-output-file p #:exists 'replace
      (λ (out) (display content out)))
    (sha256-file/hex p))
  (check-equal? (write+hash "")
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  (check-equal? (write+hash "abc")
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  (check-equal?
   (write+hash "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
   "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  (delete-directory/files base))
