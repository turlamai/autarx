#lang racket/base

(require json racket/file racket/path racket/system)

;; Windows-only product (issue #56): packaged acceptance runs on the
;; Windows host exclusively.
(define platform
  (if (eq? (system-type 'os) 'windows)
      "windows"
      (error 'autarx-acceptance
             "unsupported platform: autarx ships Windows-only")))
(define raco
  (or (find-executable-path "raco")
      (error 'autarx-acceptance "raco was not found")))
(unless (system* raco "rivet" "package" "--skip-launch-smoke")
  (error 'autarx-acceptance "raco rivet package failed"))
(define output-directory
  (build-path (current-directory) ".rivet" "acceptance" platform))
(make-directory* output-directory)
(call-with-output-file (build-path output-directory "package.json")
  #:exists 'truncate/replace
  (lambda (output)
    (write-json (hash 'platform platform
                      'package-verified #t
                      'source "raco rivet package --skip-launch-smoke")
                output)
    (newline output)))
