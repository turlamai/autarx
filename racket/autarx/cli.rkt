#lang racket/base

;; autarx CLI — port of Autarx.Cli (v1.0.3 contract). One Racket binary
;; that links the domain core directly (CLI/MCP never go through the
;; Rivet RPC surface). JSON profile: 2-space indent, camelCase in
;; declaration order, null omitted, string enums; exit codes 0/1/2/3.

(require racket/file
         racket/path
         racket/string
         racket/list
         json
         "arxml.rkt"
         "classify.rkt"
         "index.rkt"
         "diff.rkt"
         "impact.rkt"
         "ecuc.rkt"
         "validate.rkt"
         "comm.rkt"
         "vendor.rkt"
         "patch.rkt"
         (prefix-in u: "update.rkt")
         "jsonout.rkt")

;; Look for rivet-app-info.rktd next to the running executable (or its
;; parent, for lib/-style layouts) and return its version field.
(define (version-from-app-info)
  (define run-file (find-system-path 'run-file))
  (define exe-dir (if (path? run-file) (path-only run-file) #f))
  (define candidate-dirs
    (if exe-dir
        (list exe-dir (simplify-path (build-path exe-dir 'up)))
        (list)))
  (for/or ([dir (in-list candidate-dirs)])
    (define info (build-path dir "rivet-app-info.rktd"))
    (and (directory-exists? dir)
         (file-exists? info)
         (call-with-input-file info
           (lambda (in)
             (define doc (read in))
             (define v (if (hash? doc) (hash-ref doc 'version #f) #f))
             (and (string? v) v))))))

;; Source checkouts: read the version from the repo-root rivet.rktd — three
;; directories above this source file (racket/autarx/cli.rkt). Resolved
;; through the running module's source path (works for source and compiled
;; checkouts; an embedded raco-exe build reports a symbol instead of a path,
;; which lands on #f — there the rivet-app-info.rktd branch above is the one
;; that must succeed).
(define (version-from-manifest)
  (define src
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (variable-reference->module-source (#%variable-reference))))
  (and (path? src)
       (file-exists? src)
       (let* ([manifest (with-handlers ([exn:fail? (lambda (_) #f)])
                          (simplify-path (build-path src 'up 'up 'up "rivet.rktd")))]
              [v (and manifest
                      (file-exists? manifest)
                      (call-with-input-file manifest
                        (lambda (in)
                          (define doc (read in))
                          (define v (if (hash? doc) (hash-ref doc 'version #f) #f))
                          (and (string? v) v))))])
         v)))

;; Release identity, single-sourced on rivet.rktd. Distributed CLI builds
;; carry a rivet-app-info.rktd beside the launcher (scripts/build-cli.sh
;; writes it from rivet.rktd); source checkouts read the repo manifest.
;; There is deliberately no version literal here — a build that cannot find
;; either file is a packaging bug and must fail loudly instead of reporting
;; a stale version (scripts/check-release-version.sh guards the source).
(define autarx-version
  (or (version-from-app-info)
      (version-from-manifest)
      (error 'autarx
             "cannot determine version: no rivet-app-info.rktd beside the launcher and no source rivet.rktd")))

(module+ main
  (exit (run (vector->list (current-command-line-arguments)))))

;; ---------------------------------------------------------------- shared

(define (run args)
  (with-handlers ([exn:fail?
                   (λ (ex)
                     (define log-path (write-crash-log "cli" ex))
                     (eprintf "autarx: unexpected failure: ~a\n" (exn-message ex))
                     (when log-path
                       (eprintf "autarx: crash log written to ~a\n" log-path))
                     3)])
    (dispatch args)))

(define (write-crash-log source ex)
  (with-handlers ([exn:fail? (λ (_) #f)])
    (define dir (build-path (find-system-path 'temp-dir) "autarx" "crashes"))
    (make-directory* dir)
    (define d (seconds->date (current-seconds) 0))
    (define path
      (build-path dir (format "autarx-~a-~a~a~a-~a~a~a~a-~a~a~a~a.log"
                              source
                              (date-year d)
                              (pad2 (date-month d)) ""
                              (pad2 (date-day d)) ""
                              (pad2 (date-hour d)) ""
                              (pad2 (date-minute d)) ""
                              (pad2 (date-second d)) "")))
    (call-with-output-file path
      (λ (out)
        (fprintf out "autarx ~a crash — ~a\n\n~a\n\n~a\n"
                 source
                 (date->iso d)
                 (exn-message ex)
                 ""))
      #:exists 'replace)
    (path->string path)))

(define (date->iso d)
  (format "~a-~a-~aT~a:~a:~aZ"
          (date-year d) (pad2 (date-month d)) (pad2 (date-day d))
          (pad2 (date-hour d)) (pad2 (date-minute d)) (pad2 (date-second d))))

(define (pad2 n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

(define (dispatch args)
  (cond
    [(null? args) (usage 2)]
    [(member (car args) '("-h" "--help" "help")) (usage 0)]
    [(member (car args) '("--version" "-v"))
     (printf "autarx ~a\n" autarx-version)
     0]
    [else
     (define cmd (car args))
     (define rest (cdr args))
     (case cmd
       [("inspect") (cmd-inspect rest)]
       [("find") (cmd-find rest)]
       [("refs") (cmd-refs rest)]
       [("trace") (cmd-trace rest)]
       [("ecus") (cmd-ecus rest)]
       [("ecu") (cmd-ecu rest)]
       [("unresolved") (cmd-unresolved rest)]
       [("diff") (cmd-diff rest)]
       [("impact") (cmd-impact rest)]
       [("comm") (cmd-comm rest)]
       [("vendor") (cmd-vendor rest)]
       [("patch") (cmd-patch rest)]
       [("mcp")
        (if (not (null? rest))
            (begin
              (eprintf "autarx: 'mcp' takes no arguments — try 'autarx --help'\n")
              2)
            (mcp-serve))]
       [("update") (cmd-update rest)]
       [("info") (cmd-info rest)]
       [("modules") (cmd-modules rest)]
       [("validate") (cmd-validate rest)]
       [else
        (eprintf "autarx: unknown command '~a' — try 'autarx --help'\n" cmd)
        2])]))

;; ---- formatting helpers (.NET alignment and N0 numeric format)

(define (fmt-n0 n)
  ;; thousands separators, no decimals (invariant culture)
  (define digits (number->string n))
  (define len (string-length digits))
  (let loop ([i 0] [out '()])
    (if (>= i len)
        (list->string (reverse out))
        (let* ([from-right (- len i)])
          (loop (add1 i)
                (if (and (> i 0) (= (remainder from-right 3) 0))
                    (cons (string-ref digits i) (cons #\, out))
                    (cons (string-ref digits i) out)))))))

(define (pad-left-str s width)
  ;; {x,-N} left-aligned
  (define len (string-length s))
  (if (>= len width) s (string-append s (make-string (- width len) #\space))))

(define (out-ln . parts) (displayln (apply string-append parts)))

;; ---- workspace loading with the CLI error mapping

(define (load-workspace path)
  (with-handlers
      ([exn:fail:filesystem?
        (λ (ex)
          (if (string-contains? (exn-message ex) "workspace path not found")
              (eprintf "autarx: workspace not found: ~a\n" path)
              (eprintf "autarx: cannot read workspace: ~a\n" (exn-message ex)))
          #f)]
       [exn:fail:autarx:parse?
        (λ (ex)
          (define location
            (if (> (exn:fail:autarx:parse-line ex) 0)
                (format " (line ~a)" (exn:fail:autarx:parse-line ex))
                ""))
          (eprintf "autarx: invalid ARXML~a: ~a\n" location (exn-message ex))
          #f)]
       [exn:fail:filesystem?
        (λ (ex)
          (eprintf "autarx: cannot read workspace: ~a\n" (exn-message ex))
          #f)])
    (build-workspace-index path)))

;; resolves and prints the standard messages; 'found object or
;; '(not-found) / '(ambiguous candidates) markers (exit code decisions
;; belong to the caller — refs/trace use 1 for both, ecu distinguishes)
(define (resolve-and-report index name-or-path)
  (define resolution (resolve-object index name-or-path))
  (case (resolution-status resolution)
    [(found) (resolution-object resolution)]
    [(not-found)
     (eprintf "autarx: no workspace object matches '~a' (paths start with '/', names are exact SHORT-NAMEs)\n"
              name-or-path)
     'not-found]
    [else
     (eprintf "autarx: '~a' is ambiguous, ~a objects match:\n"
              name-or-path
              (length (resolution-candidates resolution)))
     (for ([c (in-list (resolution-candidates resolution))])
       (eprintf "  ~a\n" (semantic-object-absolute-path c)))
     'ambiguous]))

;; ---- shared JSON DTO fragments

(define (object-json o)
  ;; CLI ObjectJson declaration order
  (list (cons "shortName" (semantic-object-short-name o))
        (cons "semanticKind" (hash-ref kind->json (semantic-object-kind o)))
        (cons "elementType" (semantic-object-element-type o))
        (cons "absolutePath" (semantic-object-absolute-path o))
        (cons "sourceFile" (semantic-object-source-file o))))

(define (reference-json r)
  (list (cons "kind" (arx-reference-kind r))
        (cons "sourcePath" (arx-reference-source-path r))
        (cons "sourceElementPath" (arx-reference-source-element-path r))
        (cons "targetPath" (arx-reference-target-path r))
        (cons "sourceFile" (arx-reference-source-file r))
        (cons "resolved" (arx-reference-resolved r))))

(define (print-json v) (displayln (json->string v)))

(define (basename-of path)
  (define p (if (string? path) (string->path path) path))
  (define v (file-name-from-path p))
  (if v (path->string v) path))

(define (kind-text kind) (hash-ref kind->text kind "unknown"))

;; ---------------------------------------------------------------- inspect

(define (cmd-inspect args)
  (define-values (workspace json? _opts) (parse-single-positional args "workspace path"))
  (define ws (and workspace (load-workspace workspace)))
  (cond
    [(not ws) 2]
    [(not workspace) 2]
    [else
     (define summary (summarize ws))
     (if json?
         (print-json (inspect-json workspace ws summary))
         (begin
           (inspect-text workspace summary)
           (for ([e (in-list (workspace-index-file-errors ws))])
             (eprintf "autarx: ~a: ~a\n" (file-error-file-path e) (file-error-message e)))
           0))]))

(define (inspect-json workspace ws summary)
  (list (cons "workspace" workspace)
        (cons "fileCount" (workspace-summary-file-count summary))
        (cons "totalFileBytes" (workspace-summary-total-file-bytes summary))
        (cons "totalElementCount" (workspace-summary-total-element-count summary))
        (cons "identifiableCount" (workspace-summary-identifiable-count summary))
        (cons "packageCount" (workspace-summary-package-count summary))
        (cons "referenceCount" (workspace-summary-reference-count summary))
        (cons "unresolvedReferenceCount"
              (workspace-summary-unresolved-reference-count summary))
        (cons "duplicatePathCount" (workspace-summary-duplicate-path-count summary))
        (cons "fileErrorCount" (workspace-summary-file-error-count summary))
        (cons "autosar"
              (list (cons "namespaces" (workspace-summary-namespaces summary))
                    (cons "schemaLocations" (workspace-summary-schema-locations summary))
                    (cons "release" (or (workspace-summary-autosar-release summary)
                                               'null))
                    (cons "mixedSchema" (workspace-summary-mixed-schema summary))))
        (cons "semanticCounts"
              (map (λ (p) (cons (hash-ref kind->json (car p)) (cdr p)))
                   (workspace-summary-semantic-counts summary)))
        (cons "unknownNamedCount" (workspace-summary-unknown-named-count summary))
        (cons "fileErrors"
              (for/list ([e (in-list (workspace-index-file-errors ws))])
                (list (cons "file" (file-error-file-path e))
                      (cons "message" (file-error-message e))
                      (cons "line" (file-error-line-number e)))))))

(define (inspect-text workspace summary)
  (define release
    (or (workspace-summary-autosar-release summary) "unknown"))
  (out-ln "workspace         " workspace)
  (out-ln "files             "
          (number->string (workspace-summary-file-count summary))
          " (" (fmt-n0 (workspace-summary-total-file-bytes summary)) " B)")
  (out-ln "elements          " (fmt-n0 (workspace-summary-total-element-count summary)))
  (out-ln "identifiables     " (fmt-n0 (workspace-summary-identifiable-count summary)))
  (out-ln "packages          " (fmt-n0 (workspace-summary-package-count summary)))
  (out-ln "references        " (fmt-n0 (workspace-summary-reference-count summary))
          " (" (fmt-n0 (workspace-summary-unresolved-reference-count summary))
          " unresolved)")
  (out-ln "duplicate paths   " (fmt-n0 (workspace-summary-duplicate-path-count summary)))
  (out-ln "file errors       " (fmt-n0 (workspace-summary-file-error-count summary)))
  (out-ln "autosar release   " release
          (if (workspace-summary-mixed-schema summary)
              " (mixed schema flavours!)" ""))
  (out-ln "namespaces        "
          (number->string (length (workspace-summary-namespaces summary))) " distinct")
  (out-ln "semantic inventory:")
  (define counts (workspace-summary-semantic-counts summary))
  (for ([kind '(system ecu communication-cluster frame pdu signal
                        software-component port port-interface ecuc-module
                        ecuc-container constant)])
    (define entry (assq kind counts))
    (out-ln "  " (pad-left-str (kind-text kind) 22)
            (pad-left-fmt6 (if entry (cdr entry) 0))))
  (out-ln "  " (pad-left-str "unknown" 22)
          (pad-left-fmt6 (workspace-summary-unknown-named-count summary))))

(define (pad-left-fmt6 n)
  ;; {count,6:N0} — right-aligned in 6 columns with separators
  (define s (fmt-n0 n))
  (define len (string-length s))
  (if (>= len 6) s (string-append (make-string (- 6 len) #\space) s)))

;; shared single-positional parsing with the standard error strings
;; missing/extra-arg messages differ per command family in v1.0.3:
;; inspect says "workspace path required", the others say "expected <workspace>"
(define (parse-single-positional args what
                                [missing-msg
                                 (format "autarx: ~a required — try 'autarx --help'"
                                         what)]
                                [extra-msg
                                 (format "autarx: exactly one ~a expected" what)])
  (let loop ([args args] [positional '()] [json? #f])
    (cond
      [(null? args)
       (cond
         [(> (length positional) 1)
          (eprintf "~a\n" extra-msg)
          (values #f json? '())]
         [(null? positional)
          (eprintf "~a\n" missing-msg)
          (values #f json? '())]
         [else (values (car positional) json? '())])]
      [(string=? (car args) "--json") (loop (cdr args) positional #t)]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx --help'\n" (car args))
       (values #f json? '())]
      [else (loop (cdr args) (cons (car args) positional) json?)])))

;; ---------------------------------------------------------------- find

(define (cmd-find args)
  (define-values (positional json? _)
    (parse-two-positional args "expected <pattern> <workspace>"))
  (unless (and positional (= (length positional) 2))
    (eprintf "autarx: expected <pattern> <workspace> — try 'autarx --help'\n"))
  (cond
    [(not (and positional (= (length positional) 2))) 2]
    [else
     (define pattern (car positional))
     (define workspace (cadr positional))
     (define ws (load-workspace workspace))
     (cond
       [(not ws) 2]
       [else
        (define matches (find-by-name ws pattern))
        (if (null? matches)
            (begin
              (eprintf "autarx: no objects match '~a'\n" pattern)
              1)
            (begin
              (if json?
                  (print-json (map object-json matches))
                  (for ([o (in-list matches)])
                    (out-ln (pad-left-str (kind-text (semantic-object-kind o)) 22)
                            (pad-left-str (semantic-object-absolute-path o) 52)
                            (basename-of (semantic-object-source-file o)))))
              0))])]))

(define (parse-two-positional args what)
  (let loop ([args args] [positional '()] [json? #f])
    (cond
      [(null? args)
       (if (= (length positional) 2)
           (values (reverse positional) json? '())
           (values #f json? '()))]
      [(string=? (car args) "--json") (loop (cdr args) positional #t)]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx --help'\n" (car args))
       (values #f json? '())]
      [else (loop (cdr args) (cons (car args) positional) json?)])))

;; ---------------------------------------------------------------- refs

(define (cmd-refs args)
  (define-values (positional json? flags) (parse-refs-args args))
  (cond
    [(not (and positional (= (length positional) 2))) 2]
    [else
     (define name-or-path (car positional))
     (define workspace (cadr positional))
     (define ws (load-workspace workspace))
     (cond
       [(not ws) 2]
       [else
        (define target (resolve-and-report ws name-or-path))
        (cond
          ;; both NotFound and Ambiguous exit 1 (v1.0.3 behaviour)
          [(symbol? target) 1]
          [else
           (define outgoing (outgoing-of ws (semantic-object-absolute-path target)))
           (define incoming (incoming-of ws (semantic-object-absolute-path target)))
           (define show-incoming? (or (hash-ref flags 'incoming #f)
                                      (not (hash-ref flags 'outgoing #f))))
           (define show-outgoing? (or (hash-ref flags 'outgoing #f)
                                      (not (hash-ref flags 'incoming #f))))
           (if json?
               (print-json
                (list (cons "object" (object-json target))
                      (cons "outgoing"
                            (if show-outgoing? (map reference-json outgoing) '()))
                      (cons "incoming"
                            (if show-incoming? (map reference-json incoming) '()))))
               (begin
                 (out-ln "object    " (semantic-object-absolute-path target)
                         " (" (kind-text (semantic-object-kind target)) ")")
                 (refs-section "outgoing" outgoing
                               (λ (r)
                                 (string-append
                                  "  -> "
                                  (pad-left-str (arx-reference-kind r) 28)
                                  (pad-left-str (arx-reference-target-path r) 52)
                                  " via "
                                  (relative-tail
                                   (arx-reference-source-element-path r)
                                   (arx-reference-source-path r))
                                  (unresolved-tag r))))
                 (refs-section "incoming" incoming
                               (λ (r)
                                 (string-trim
                                  (string-append
                                   "  <- "
                                   (pad-left-str (arx-reference-kind r) 28)
                                   (pad-left-str (arx-reference-source-element-path r) 52)
                                   (unresolved-tag r))))))
               )
           0])])]))

(define (refs-section title refs render)
  (out-ln title " (" (number->string (length refs)) "):")
  (for ([r (in-list refs)]) (displayln (render r))))

(define (unresolved-tag r)
  (if (arx-reference-resolved r) "" "  (unresolved)"))

(define (relative-tail element-path object-path)
  (if (> (string-length element-path) (string-length object-path))
      (substring element-path (string-length object-path))
      ""))

(define (parse-refs-args args)
  (let loop ([args args] [positional '()] [json? #f] [flags (hash)])
    (cond
      [(null? args)
       (values (if (= (length positional) 2) (reverse positional) #f)
               json? flags)]
      [(string=? (car args) "--json") (loop (cdr args) positional #t flags)]
      [(string=? (car args) "--incoming")
       (loop (cdr args) positional json? (hash-set flags 'incoming #t))]
      [(string=? (car args) "--outgoing")
       (loop (cdr args) positional json? (hash-set flags 'outgoing #t))]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx --help'\n" (car args))
       (values #f json? flags)]
      [else (loop (cdr args) (cons (car args) positional) json? flags)])))

;; ---------------------------------------------------------------- trace

(define (cmd-trace args)
  (define-values (positional json? opts) (parse-trace-args args))
  (cond
    [(not positional) 2]
    [(not (= (length positional) 2))
     (eprintf "autarx: expected <name-or-path> <workspace>\n")
     2]
    [else
     (define name-or-path (car positional))
     (define workspace (cadr positional))
     (define ws (load-workspace workspace))
     (cond
       [(not ws) 2]
       [else
        (define target (resolve-and-report ws name-or-path))
        (cond
          [(symbol? target) 1]
          [else
           (define direction
             (hash-ref opts 'direction 'both))
           (define depth (hash-ref opts 'depth 2))
           (define result (trace ws (semantic-object-absolute-path target)
                                 direction depth))
           (if json?
               (print-json
                (list (cons "root" (trace-result-root result))
                      (cons "direction" (symbol->json-direction
                                         (trace-result-direction result)))
                      (cons "maxDepth" (trace-result-max-depth result))
                      (cons "nodes"
                            (for/list ([n (in-list (trace-result-nodes result))])
                              (list (cons "path" (trace-node-path n))
                                    (cons "depth" (trace-node-depth n)))))
                      (cons "edges"
                            (for/list ([e (in-list (trace-result-edges result))])
                              (list (cons "sourcePath" (trace-edge-source-path e))
                                    (cons "kind" (trace-edge-kind e))
                                    (cons "targetPath" (trace-edge-target-path e))
                                    (cons "depth" (trace-edge-depth e)))))))
               (begin
                 (out-ln "trace from " (trace-result-root result)
                         " (depth " (number->string (trace-result-max-depth result))
                         ", " (symbol->string (trace-result-direction result)) "):")
                 (for ([e (in-list (trace-result-edges result))])
                   (out-ln "  [" (number->string (trace-edge-depth e)) "] "
                           (pad-left-str (trace-edge-kind e) 28)
                           (trace-edge-source-path e) " -> " (trace-edge-target-path e)))
                 (out-ln (number->string (length (trace-result-nodes result)))
                         " object(s) reachable, "
                         (number->string (length (trace-result-edges result)))
                         " edge(s)")))
           0])])]))

(define (symbol->json-direction d)
  (case d [(outgoing) "outgoing"] [(incoming) "incoming"] [else "both"]))

(define (parse-trace-args args)
  (let loop ([args args] [positional '()] [json? #f] [opts (hash)])
    (cond
      [(null? args) (values (if (null? positional) #f (reverse positional)) json? opts)]
      [(string=? (car args) "--json") (loop (cdr args) positional #t opts)]
      [(string=? (car args) "--depth")
       (if (or (null? (cdr args))
               (not (string->number (cadr args)))
               (negative? (string->number (cadr args))))
           (begin
             (eprintf
              "autarx: --depth requires a non-negative number, e.g. --depth 3\n")
             (values #f json? opts))
           (loop (cddr args) positional json?
                 (hash-set opts 'depth (string->number (cadr args)))))]
      [(member (car args) '("--incoming" "--outgoing" "--both"))
       (loop (cdr args) positional json?
             (hash-set opts 'direction
                       (string->symbol (substring (car args) 2))))]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx --help'\n" (car args))
       (values #f json? opts)]
      [else (loop (cdr args) (cons (car args) positional) json? opts)])))

;; ---------------------------------------------------------------- ecus / ecu

(define (cmd-ecus args)
  (define-values (workspace json? _)
    (parse-single-positional args
                             "workspace path"
                             "autarx: expected <workspace> — try 'autarx --help'"
                             "autarx: expected <workspace>"))
  (define ws (and workspace (load-workspace workspace)))
  (cond
    [(not ws) 2]
    [(not workspace) 2]
    [else
     (define ecus
       (sort (filter (λ (o) (eq? (semantic-object-kind o) 'ecu))
                     (workspace-index-objects ws))
             string<?
             #:key semantic-object-absolute-path))
     (if (null? ecus)
         (begin
           (eprintf "autarx: no ECU instances found in workspace\n")
           1)
         (begin
           (if json?
               (print-json (map object-json ecus))
               (for ([o (in-list ecus)])
                 (out-ln (pad-left-str (semantic-object-short-name o) 20)
                         (pad-left-str (semantic-object-absolute-path o) 52)
                         (basename-of (semantic-object-source-file o)))))
           0))]))

(define (cmd-ecu args)
  (define positional+json (parse-ecu-detail-args args))
  (cond
    [(not positional+json) 2]
    [else
     (define positional (car positional+json))
     (define json? (cdr positional+json))
     (cond
       [(not (= (length positional) 2))
        (eprintf "autarx: expected <workspace> <ecu-name>\n") 2]
       [else
        (define workspace (car positional))
        (define ecu-name (cadr positional))
        (define ws (load-workspace workspace))
        (cond
          [(not ws) 2]
          [else
           (define target (resolve-and-report ws ecu-name))
           (cond
             [(eq? target 'ambiguous) 2]
             [(eq? target 'not-found) 1]
             [(not (eq? (semantic-object-kind target) 'ecu))
              (eprintf "autarx: '~a' is a ~a, not an ECU instance\n"
                       ecu-name (kind-text (semantic-object-kind target)))
              1]
             [else
              (define path (semantic-object-absolute-path target))
              (define outgoing (outgoing-of ws path))
              (define incoming (incoming-of ws path))
              ;; related list, sorted by path then direction
              (define by-path (make-hash))
              (for ([o (in-list (workspace-index-objects ws))])
                (hash-set! by-path (semantic-object-absolute-path o) o))
              (define related
                (sort
                 (append
                  (for/list ([r (in-list outgoing)])
                    (list (arx-reference-target-path r) "outgoing"
                          (arx-reference-kind r)))
                  (for/list ([r (in-list incoming)])
                    (list (arx-reference-source-path r) "incoming"
                          (arx-reference-kind r))))
                 (λ (a b)
                   (define pa (car a)) (define pb (car b))
                   (cond
                     [(not (string=? pa pb)) (string<? pa pb)]
                     [else (string<? (cadr a) (cadr b))]))))
              (if json?
                  (print-json
                   (list (cons "ecu" (object-json target))
                         (cons "outgoing" (map reference-json outgoing))
                         (cons "incoming" (map reference-json incoming))
                         (cons "related"
                               (for/list ([entry (in-list related)])
                                 (define other
                                   (hash-ref by-path (car entry) #f))
                                 (list (cons "path" (car entry))
                                       (cons "semanticKind"
                                             (if other
                                                 (hash-ref kind->json
                                                           (semantic-object-kind other))
                                                 'null))
                                       (cons "direction" (cadr entry))
                                       (cons "viaKind" (caddr entry))
                                       (cons "relationshipConfidence" "direct"))))))
                  (begin
                    (out-ln (semantic-object-short-name target)
                            " (" (kind-text (semantic-object-kind target)) ")")
                    (out-ln "  path   " path)
                    (out-ln "  file   " (basename-of (semantic-object-source-file target)))
                    (refs-section "  outgoing references" outgoing
                                  (λ (r)
                                    (string-append
                                     "    -> "
                                     (pad-left-str (arx-reference-kind r) 28)
                                     (arx-reference-target-path r)
                                     (unresolved-tag r))))
                    (refs-section "  incoming references" incoming
                                  (λ (r)
                                    (string-append
                                     "    <- "
                                     (pad-left-str (arx-reference-kind r) 28)
                                     (arx-reference-source-element-path r))))
                    (out-ln "  related objects ("
                            (number->string (length related)) "):")
                    (for ([entry (in-list related)])
                      (out-ln "    " (pad-left-str "direct" 8)
                              (pad-left-str (cadr entry) 8)
                              " via " (pad-left-str (caddr entry) 28)
                              (car entry)))))
              0])])])]))

(define (parse-ecu-detail-args args)
  (let loop ([args args] [positional '()] [json? #f])
    (cond
      [(null? args)
       (if (> (length positional) 2)
           (begin (eprintf "autarx: expected <workspace> <ecu-name>\n") #f)
           (cons (reverse positional) json?))]
      [(string=? (car args) "--json") (loop (cdr args) positional #t)]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx --help'\n" (car args))
       #f]
      [else (loop (cdr args) (cons (car args) positional) json?)])))

;; ---------------------------------------------------------------- unresolved

(define (cmd-unresolved args)
  (define-values (workspace json? _)
    (parse-single-positional args
                             "workspace path"
                             "autarx: expected <workspace> — try 'autarx --help'"
                             "autarx: expected <workspace>"))
  (define ws (and workspace (load-workspace workspace)))
  (cond
    [(not ws) 2]
    [(not workspace) 2]
    [else
     (define unresolved
       (filter (λ (r) (not (arx-reference-resolved r)))
               (workspace-index-references ws)))
     (if json?
         (print-json (map reference-json unresolved))
         (begin
           (for ([r (in-list unresolved)])
             (out-ln (pad-left-str (arx-reference-source-element-path r) 60)
                     " -[" (arx-reference-kind r) "]-> "
                     (arx-reference-target-path r)
                     " (" (basename-of (arx-reference-source-file r)) ")"))
           (out-ln (number->string (length unresolved))
                   " unresolved reference(s)")))
     (if (null? unresolved) 0 1)]))

;; ---------------------------------------------------------------- diff

(define (cmd-diff args)
  (define-values (positional json? detail?)
    (parse-diff-args args "expected <before> <after>"))
  (cond
    [(not (and positional (= (length positional) 2))) 2]
    [else
     (define before (load-workspace (car positional)))
     (define after (and before (load-workspace (cadr positional))))
     (cond
       [(not (and before after)) 2]
       [else
        (define d (compare-workspaces before after detail?))
        (if json?
            (print-json (diff-json d))
            (render-diff-text d))
        (if (workspace-diff-empty? d) 0 1)])]))

(define (diff-json d)
  (list (cons "before" (side-json (workspace-diff-before d)))
        (cons "after" (side-json (workspace-diff-after d)))
        (cons "objects" (map object-change-json (workspace-diff-objects d)))
        (cons "references" (map reference-change-json (workspace-diff-references d)))
        (cons "files" (map file-change-json (workspace-diff-files d)))))

(define (side-json side)
  (list (cons "path" (diff-side-path side))
        (cons "documents" (diff-side-document-count side))
        (cons "objects" (diff-side-object-count side))
        (cons "references" (diff-side-reference-count side))))

(define (object-change-json c)
  (list (cons "changeType" (symbol->json-change (object-change-change-type c)))
        (cons "shortName" (object-change-short-name c))
        (cons "semanticKind" (hash-ref kind->json (object-change-kind c)))
        (cons "absolutePath" (object-change-absolute-path c))
        (cons "beforeElementType" (or (object-change-before-element-type c) 'null))
        (cons "afterElementType" (or (object-change-after-element-type c) 'null))
        (cons "elementTypeChanged" (object-change-element-type-changed? c))
        (cons "properties"
              (if (object-change-properties c)
                  (map property-change-json (object-change-properties c))
                  'null))))

(define (property-change-json p)
  (list (cons "path" (property-change-path p))
        (cons "changeType" (symbol->json-property-change (property-change-change p)))
        (cons "before" (or (property-change-before p) 'null))
        (cons "after" (or (property-change-after p) 'null))))

(define (reference-change-json r)
  (list (cons "changeType" (symbol->json-change (reference-change-change-type r)))
        (cons "sourcePath" (reference-change-source-path r))
        (cons "kind" (reference-change-kind r))
        (cons "targetPath" (reference-change-target-path r))
        (cons "sourceFile" (or (and (reference-change-source-file r)
                                    (basename-of (reference-change-source-file r)))
                               'null))))

(define (file-change-json f)
  (list (cons "changeType" (symbol->json-change (file-change-change-type f)))
        (cons "relativePath" (file-change-relative-path f))
        (cons "beforeSizeBytes" (or (file-change-before-size-bytes f) 'null))
        (cons "afterSizeBytes" (or (file-change-after-size-bytes f) 'null))))

(define (symbol->json-change s)
  (case s [(added) "added"] [(removed) "removed"] [else "modified"]))

(define (symbol->json-property-change s)
  (case s [(added) "added"] [(removed) "removed"] [else "changed"]))

(define (render-diff-text d)
  (out-ln "before: " (number->string (diff-side-document-count (workspace-diff-before d)))
          " files, " (number->string (diff-side-object-count (workspace-diff-before d)))
          " objects, "
          (number->string (diff-side-reference-count (workspace-diff-before d)))
          " references — " (diff-side-path (workspace-diff-before d)))
  (out-ln "after:  " (number->string (diff-side-document-count (workspace-diff-after d)))
          " files, " (number->string (diff-side-object-count (workspace-diff-after d)))
          " objects, "
          (number->string (diff-side-reference-count (workspace-diff-after d)))
          " references — " (diff-side-path (workspace-diff-after d)))
  (define objects (workspace-diff-objects d))
  (define references (workspace-diff-references d))
  (define files (workspace-diff-files d))
  (if (and (null? objects) (null? references) (null? files))
      (out-ln "no semantic differences")
      (let ()
        (define added (filter (λ (c) (eq? (object-change-change-type c) 'added)) objects))
        (define removed (filter (λ (c) (eq? (object-change-change-type c) 'removed)) objects))
        (define modified (filter (λ (c) (eq? (object-change-change-type c) 'modified))
                                 objects))
        (define refs-added
          (filter (λ (r) (eq? (reference-change-change-type r) 'added)) references))
        (define refs-removed
          (filter (λ (r) (eq? (reference-change-change-type r) 'removed)) references))
        (unless (null? added)
          (out-ln "")
          (out-ln "added (" (number->string (length added)) "):")
          (for ([c (in-list added)])
            (out-ln "  + " (or (object-change-element-type c) "?") " "
                    (object-change-absolute-path c))))
        (unless (null? removed)
          (out-ln "")
          (out-ln "removed (" (number->string (length removed)) "):")
          (for ([c (in-list removed)])
            (out-ln "  - " (or (object-change-element-type c) "?") " "
                    (object-change-absolute-path c))))
        (unless (null? modified)
          (out-ln "")
          (out-ln "modified (" (number->string (length modified)) "):")
          (for ([c (in-list modified)])
            (define type-prefix
              (if (object-change-element-type-changed? c)
                  (string-append (object-change-before-element-type c) " → "
                                 (object-change-after-element-type c) " ")
                  (string-append (or (object-change-element-type c) "?") " ")))
            (out-ln "  ~ " type-prefix (object-change-absolute-path c))
            (for ([p (in-list (or (object-change-properties c) '()))])
              (out-ln "    " (property-change-path p) ": "
                      (or (property-change-before p) "(absent)") " → "
                      (or (property-change-after p) "(absent)")))))
        (unless (and (null? refs-added) (null? refs-removed))
          (out-ln "")
          (out-ln "references ("
                  (number->string (+ (length refs-added) (length refs-removed))) "):")
          (for ([r (in-list refs-added)])
            (out-ln "  + " (reference-change-kind r) " "
                    (reference-change-source-path r) " -> "
                    (reference-change-target-path r)))
          (for ([r (in-list refs-removed)])
            (out-ln "  - " (reference-change-kind r) " "
                    (reference-change-source-path r) " -> "
                    (reference-change-target-path r))))
        (unless (null? files)
          (out-ln "")
          (out-ln "files (" (number->string (length files)) "):")
          (for ([f (in-list files)])
            (define marker
              (case (file-change-change-type f)
                [(added) "+"] [(removed) "-"] [else "~"]))
            (define suffix
              (if (eq? (file-change-change-type f) 'modified)
                  (format " (~a → ~a bytes)"
                          (file-change-before-size-bytes f)
                          (file-change-after-size-bytes f))
                  ""))
            (out-ln "  " marker (file-change-relative-path f) suffix)))))
  (if (and (null? objects) (null? references) (null? files)) 0 1))

;; ---------------------------------------------------------------- usage

(define (usage [exit-code 2])
  (displayln
   (string-append
    "autarx " autarx-version " — AUTOSAR Integration Workbench\n"
    "\n"
    "Inspect, understand, compare, trace and automate OEM-to-supplier\n"
    "integration data. Autarx sits above the vendor generators — it does\n"
    "not replace DaVinci, tresos or ISOLAR, and it does not generate\n"
    "production BSW/RTE/MCAL code.\n"
    "\n"
    "Usage:\n"
    "  autarx <command> [options] <file-or-directory>\n"
    "\n"
    "Workspace commands (file or directory):\n"
    "  inspect     Summarize a workspace (files, semantic inventory, references)\n"
    "  find        Find identifiables by SHORT-NAME substring\n"
    "  refs        Show outgoing/incoming references of an object\n"
    "  trace       Follow the reference graph from an object (BFS, depth-limited)\n"
    "  ecus        List ECU instances in a workspace\n"
    "  ecu         Show one ECU instance and its direct relations\n"
    "  unresolved  List references whose target is not in the workspace\n"
    "  diff        Semantic diff between two deliveries\n"
    "              diff <before> <after> [--detail]\n"
    "  impact      ECU-scoped impact analysis across two deliveries\n"
    "              impact <before> <after> --ecu <name> [--detail]\n"
    "  comm        Communication projection: clusters, frames, PDUs,\n"
    "              signals — and what is not attached anywhere\n"
    "              comm <workspace> [--cluster <name>]\n"
    "\n"
    "Vendor tools (hand-off only — no generation is reimplemented):\n"
    "  vendor      Detect DaVinci / tresos / ISOLAR and relay their\n"
    "              validation runs\n"
    "              vendor list · vendor validate <tool> <project>\n"
    "\n"
    "Reviewed editing (plan → diff → apply → undo):\n"
    "  patch       Semantic rename / ECUC parameter / reference edits;\n"
    "              every write is gated by a semantic diff\n"
    "              patch plan|apply <ws> --file ops.json · patch undo <ws>\n"
    "\n"
    "AI agents:\n"
    "  mcp         Run the MCP stdio server (JSON-RPC 2.0) exposing\n"
    "              the full tool API with workspace audit logging\n"
    "\n"
    "Self-update:\n"
    "  update      Check the signed release feed and self-apply newer builds\n"
    "              update [--check] [--json] [--feed <https-url>]\n"
    "\n"
    "Single-file commands:\n"
    "  info        Summarize a single ARXML file\n"
    "  modules     List ECUC module configurations in a file\n"
    "  validate    Structural checks only — XML correctness, workspace\n"
    "              integrity, broken references, duplicate paths.\n"
    "              NOT vendor validation: use DaVinci / tresos / ISOLAR\n"
    "              for production-grade validation.\n"
    "\n"
    "Options:\n"
    "  --json      Machine-readable JSON output (camelCase, deterministic)\n"
    "  -h, --help  Show this help\n"
    "  --version   Show version\n"
    "\n"
    "Exit codes:\n"
    "  0  success\n"
    "  1  nothing matched (find/refs/trace/ecu) or findings reported\n"
    "     (validate/unresolved/diff/impact); update --check: newer\n"
    "     release available\n"
    "  2  usage, file, or parse error, or ambiguous object name\n"
    "  3  unhandled crash (a log was written under <TEMP>/autarx/crashes)"))
  exit-code)

;; ---- arg parsing shared by diff/impact

(define (parse-diff-args args what)
  (let loop ([args args] [positional '()] [json? #f] [detail? #f])
    (cond
      [(null? args)
       (values (if (= (length positional) 2) (reverse positional) #f) json? detail?)]
      [(string=? (car args) "--json") (loop (cdr args) positional #t detail?)]
      [(string=? (car args) "--detail") (loop (cdr args) positional json? #t)]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx --help'\n" (car args))
       (values #f json? detail?)]
      [else (loop (cdr args) (cons (car args) positional) json? detail?)])))

;; ---------------------------------------------------------------- impact

(define (cmd-impact args)
  (define parsed (parse-impact-args args))
  (cond
    [(not parsed) 2]
    [else
     (define positional (car parsed))
     (define json? (cadr parsed))
     (define detail? (caddr parsed))
     (define ecu-name (cadddr parsed))
     (cond
       [(not (= (length positional) 2))
        (eprintf "autarx: expected <before> <after> --ecu <name>\n")
        2]
       [else
        (define before (load-workspace (car positional)))
        (define after (and before (load-workspace (cadr positional))))
        (cond
          [(not (and before after)) 2]
          [else
           ;; ECU resolution: after first, then before (removed-ECU case)
           (define after-resolution (resolve-object after ecu-name))
           (define before-resolution (resolve-object before ecu-name))
           (define ecu-object
             (cond
               [(eq? (resolution-status after-resolution) 'found)
                (resolution-object after-resolution)]
               [(eq? (resolution-status before-resolution) 'found)
                (resolution-object before-resolution)]
               [else #f]))
           (cond
             [(or (eq? (resolution-status after-resolution) 'ambiguous)
                  (eq? (resolution-status before-resolution) 'ambiguous))
              (eprintf "autarx: '~a' is ambiguous, ~a objects match:\n" ecu-name
                       (length (resolution-candidates
                                (if (eq? (resolution-status after-resolution) 'ambiguous)
                                    after-resolution
                                    before-resolution))))
              (for ([c (in-list (resolution-candidates
                                 (if (eq? (resolution-status after-resolution)
                                          'ambiguous)
                                     after-resolution
                                     before-resolution)))])
                (eprintf "  ~a\n" (semantic-object-absolute-path c)))
              2]
             [(not ecu-object)
              (eprintf
               "autarx: no workspace object matches '~a' in either delivery\n"
               ecu-name)
              2]
             [(not (eq? (semantic-object-kind ecu-object) 'ecu))
              (eprintf "autarx: '~a' is a ~a, not an ECU instance\n"
                       ecu-name (kind-text (semantic-object-kind ecu-object)))
              2]
             [else
              (define ecu-path (semantic-object-absolute-path ecu-object))
              (define ecu-removed?
                (and (eq? (resolution-status after-resolution) 'not-found)
                     (eq? (resolution-status before-resolution) 'found)))
              (define d (compare-workspaces before after detail?))
              (define report
                (analyze-impact before after ecu-path ecu-removed? d detail?))
              (if json?
                  (print-json (impact-json report))
                  (let ()
                    (out-ln "impact for " (impact-report-ecu report) " ("
                            (impact-report-ecu-path report) ") — "
                            (if (impact-report-ecu-removed report)
                                "ECU not present in after delivery"
                                "ECU present in after delivery"))
                    (out-ln "closure: "
                            (number->string (impact-report-closure-size report))
                            " objects in scope, relevant changes: "
                            (number->string (impact-report-relevant-count report))
                            ", unrelated: "
                            (number->string (impact-report-unrelated-count report))
                            ", breaking: "
                            (number->string (impact-report-breaking-count report)))
                    (unless (null? (impact-report-findings report))
                      (out-ln "findings:")
                      (for ([f (in-list (impact-report-findings report))])
                        (out-ln "  [" (symbol->string (impact-finding-severity f)) "] "
                                (impact-finding-rule f) " "
                                (impact-finding-object-path f))))
                    (define comm (impact-report-communication report))
                    (unless (null? (communication-impact-changes comm))
                      (out-ln "communication impact: "
                              (number->string
                               (communication-impact-cluster-count comm))
                              " cluster(s), "
                              (number->string (communication-impact-frame-count comm))
                              " frame(s), "
                              (number->string (communication-impact-pdu-count comm))
                              " PDU(s), "
                              (number->string
                               (communication-impact-signal-count comm))
                              " signal(s)"))))
              (if (or (> (impact-report-relevant-count report) 0)
                      (not (null? (impact-report-findings report))))
                  1
                  0)])])])]))

(define (impact-json report)
  (list (cons "ecu" (impact-report-ecu report))
        (cons "ecuPath" (impact-report-ecu-path report))
        (cons "ecuRemoved" (impact-report-ecu-removed report))
        (cons "closureSize" (impact-report-closure-size report))
        (cons "relevantCount" (impact-report-relevant-count report))
        (cons "unrelatedCount" (impact-report-unrelated-count report))
        (cons "breakingCount" (impact-report-breaking-count report))
        (cons "findings"
              (for/list ([f (in-list (impact-report-findings report))])
                (list (cons "rule" (impact-finding-rule f))
                      (cons "severity"
                            (if (eq? (impact-finding-severity f) 'breaking)
                                "breaking" "info"))
                      (cons "objectPath" (impact-finding-object-path f))
                      (cons "detail" (impact-finding-detail f)))))
        (cons "relevantChanges"
              (map object-change-json (impact-report-relevant-changes report)))
        (cons "communication"
              (let ([c (impact-report-communication report)])
                (list (cons "changes"
                            (map object-change-json (communication-impact-changes c)))
                      (cons "signalCount" (communication-impact-signal-count c))
                      (cons "pduCount" (communication-impact-pdu-count c))
                      (cons "frameCount" (communication-impact-frame-count c))
                      (cons "clusterCount" (communication-impact-cluster-count c)))))))

(define (parse-impact-args args)
  (let loop ([args args] [positional '()] [json? #f] [detail? #f] [ecu #f])
    (cond
      [(null? args)
       (if (and (= (length positional) 2) ecu)
           (list (reverse positional) json? detail? ecu)
           (begin
             (eprintf "autarx: expected <before> <after> --ecu <name>\n")
             #f))]
      [(string=? (car args) "--json") (loop (cdr args) positional #t detail? ecu)]
      [(string=? (car args) "--detail") (loop (cdr args) positional json? #t ecu)]
      [(string=? (car args) "--ecu")
       (if (null? (cdr args))
           (begin (eprintf "autarx: --ecu requires a value\n") #f)
           (loop (cddr args) positional json? detail? (cadr args)))]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx --help'\n" (car args))
       #f]
      [else (loop (cdr args) (cons (car args) positional) json? detail? ecu)])))

;; ---------------------------------------------------------------- comm

(define (cmd-comm args)
  (define parsed (parse-comm-args args))
  (cond
    [(not parsed) 2]
    [else
     (define positional (car parsed))
     (define json? (cadr parsed))
     (define cluster-name (caddr parsed))
     (cond
       [(or (> (length positional) 1) (null? positional))
        (eprintf "autarx: expected <workspace>\n")
        2]
       [else
        (define workspace (car positional))
        (define ws (load-workspace workspace))
        (cond
          [(not ws) 2]
          [else
           (define model (build-communication ws))
           ;; cluster filter semantics
(define filtered-model
            (if cluster-name
                (filter-comm-cluster model ws cluster-name)
                model))
           (cond
             [(eq? filtered-model 'error) 1]
             [(and (not cluster-name) (communication-model-empty? filtered-model)
                   (null? (communication-model-orphan-frames filtered-model))
                   (null? (communication-model-orphan-pdus filtered-model))
                   (null? (communication-model-orphan-signals filtered-model)))
              (eprintf "autarx: no communication content found in workspace\n")
              1]
             [else
              (if json?
                  (print-json (comm-json filtered-model))
                  (render-comm-text filtered-model ws))
              0])])])]))

(define (comm-json m)
  (list (cons "clusters"
              (for/list ([c (in-list (communication-model-clusters m))])
                (list (cons "clusterPath" (cluster-projection-cluster-path c))
                      (cons "connectedEcus" (cluster-projection-connected-ecus c))
                      (cons "framePaths" (cluster-projection-frame-paths c)))))
        (cons "frames"
              (for/list ([f (in-list (communication-model-frames m))])
                (list (cons "framePath" (frame-projection-frame-path f))
                      (cons "pduPaths" (frame-projection-pdu-paths f)))))
        (cons "pdus"
              (for/list ([p (in-list (communication-model-pdus m))])
                (list (cons "pduPath" (pdu-projection-pdu-path p))
                      (cons "signalPaths" (pdu-projection-signal-paths p)))))
        (cons "orphanFrames" (communication-model-orphan-frames m))
        (cons "orphanPdus" (communication-model-orphan-pdus m))
        (cons "orphanSignals" (communication-model-orphan-signals m))
        (cons "ecucCommModules" (communication-model-ecuc-comm-modules m))))

(define (parse-comm-args args)
  (let loop ([args args] [positional '()] [json? #f] [cluster #f])
    (cond
      [(null? args)
       (if (or (> (length positional) 1) (null? positional))
           (begin
             (eprintf "autarx: expected <workspace> — try 'autarx --help'\n")
             #f)
           (list (reverse positional) json? cluster))]
      [(string=? (car args) "--json") (loop (cdr args) positional #t cluster)]
      [(string=? (car args) "--cluster")
       (if (null? (cdr args))
           (begin (eprintf "autarx: --cluster requires a value\n") #f)
           (loop (cddr args) positional json? (cadr args)))]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx --help'\n" (car args))
       #f]
      [else (loop (cdr args) (cons (car args) positional) json? cluster)])))

(define (render-comm-text m ws)
  (define by-path (make-hash))
  (for ([o (in-list (workspace-index-objects ws))])
    (hash-set! by-path (semantic-object-absolute-path o) o))
  (define (short-of path)
    (define o (hash-ref by-path path #f))
    (if o (semantic-object-short-name o) path))
  (for ([c (in-list (communication-model-clusters m))])
    (define path (cluster-projection-cluster-path c))
    (out-ln (short-of path) " (" path ")")
    (define ecus (cluster-projection-connected-ecus c))
    (out-ln "  ecus: "
            (if (null? ecus)
                "(none)"
                (string-join (map short-of ecus) ", ")))
    (define frame-paths (cluster-projection-frame-paths c))
    (if (null? frame-paths)
        (out-ln "  frames: (none — no frame triggerings under this cluster)")
        (begin
          (out-ln "  frames:")
          (for ([fp (in-list frame-paths)])
            (out-ln "  frame " (short-of fp))
            (define frame-entry
              (for/or ([f (in-list (communication-model-frames m))])
                (and (string=? (frame-projection-frame-path f) fp) f)))
            (define pdus (or (and frame-entry (frame-projection-pdu-paths frame-entry))
                             '()))
            (if (null? pdus)
                (out-ln "    pdus: (none — no PDU-to-frame mapping)")
                (for ([pp (in-list pdus)])
                  (define pdu-entry
                    (for/or ([p (in-list (communication-model-pdus m))])
                      (and (string=? (pdu-projection-pdu-path p) pp) p)))
                  (define signals
                    (or (and pdu-entry (pdu-projection-signal-paths pdu-entry)) '()))
                  (out-ln "    pdu " (short-of pp) "  signals: "
                          (if (null? signals)
                              "(none)"
                              (string-join (map short-of signals) ", ")))))))))
  (define (orphans title paths)
    (unless (null? paths)
      (out-ln "")
      (out-ln title " (" (number->string (length paths))
              ") — not attached to any parent:")
      (for ([p (in-list paths)]) (out-ln "  " p))))
  (orphans "orphan frames" (communication-model-orphan-frames m))
  (orphans "orphan pdus" (communication-model-orphan-pdus m))
  (orphans "orphan signals" (communication-model-orphan-signals m))
  (unless (null? (communication-model-ecuc-comm-modules m))
    (out-ln "")
    (out-ln "ecuc comm modules: "
            (string-join (communication-model-ecuc-comm-modules m) ", "))))

;; ---------------------------------------------------------------- vendor

(define (cmd-vendor args)
  (cond
    [(null? args) (vendor-usage 2)]
    [(member (car args) '("-h" "--help" "help")) (vendor-usage 0)]
    [(string=? (car args) "list") (vendor-list (cdr args))]
    [(string=? (car args) "validate") (vendor-validate (cdr args))]
    [else
     (eprintf "autarx: unknown vendor subcommand '~a' — try 'autarx vendor --help'\n"
              (car args))
     2]))

(define (vendor-usage exit-code)
  (displayln
   (string-append
    "autarx vendor — hand off to DaVinci / EB tresos / ISOLAR\n"
    "\n"
    "Detection probes the tool's HOME env var (DAVINCI_HOME, TRESOS_HOME,\n"
    "ISOLAR_HOME) and then PATH. Validation runs the vendor tool and relays\n"
    "its own result — autarx never judges the engineering outcome.\n"
    "\n"
    "Usage:\n"
    "  autarx vendor list [--json]\n"
    "  autarx vendor validate <tool> <project> [options]\n"
    "\n"
    "Tools: davinci · tresos · isolar\n"
    "\n"
    "Options:\n"
    "  --exe <path>     Explicit tool executable (skips detection)\n"
    "  --args <tmpl>    Argument template with {project} placeholder\n"
    "  --timeout <sec>  Timeout in seconds (default 600)\n"
    "  --json           Machine-readable JSON output\n"))
  exit-code)

(define (vendor-list args)
  (let loop ([args args] [json? #f])
    (cond
      [(null? args)
       (define tools
         (filter values
                 (for/list ([adapter (in-list vendor-adapters)])
                   (detect-vendor adapter
                                  (λ (name) (getenv name))
                                  resolve-executable))))
       (cond
         [(null? tools)
          (if json? (print-json '())
              (eprintf
               "autarx: no vendor tools detected — set DAVINCI_HOME / TRESOS_HOME / ISOLAR_HOME or put the tool on PATH\n"))
          1]
         [else
          (if json?
              (print-json
               (for/list ([t (in-list tools)])
                 (list (cons "name" (vendor-tool-name t))
                       (cons "displayName"
                             (vendor-adapter-display-name
                              (find-vendor-adapter (vendor-tool-name t))))
                       (cons "executablePath" (vendor-tool-executable-path t)))))
              (begin
                (out-ln "detected vendor tools:")
                (for ([t (in-list tools)])
                  (out-ln "  " (pad-left-str (vendor-tool-name t) 10)
                          (pad-left-str
                           (vendor-adapter-display-name
                            (find-vendor-adapter (vendor-tool-name t))) 24)
                          (vendor-tool-executable-path t)))))
          0])]
      [(string=? (car args) "--json") (loop (cdr args) #t)]
      [else
       (eprintf "autarx: unknown option — try 'autarx vendor list --help'\n")
       2])))

;; a bare name is searched on PATH; an absolute path is existence-checked
(define (resolve-executable candidate)
  (cond
    [(string-contains? candidate "/")
     (and (file-exists? candidate)
          (member (file-or-directory-permissions candidate) '(#rx""))
          candidate)]
    [else
     (for/or ([dir (in-list (string-split (or (getenv "PATH") "") ":"))]
              #:when (> (string-length dir) 0))
       (define p (string-append dir "/" candidate))
       (and (file-exists? p) p))]))

(define (vendor-validate args)
  (define parsed (parse-vendor-validate args))
  (cond
    [(not parsed) 2]
    [else
     (define positional (car parsed))
     (define opts (cadr parsed))
     (cond
       [(not (= (length positional) 2))
        (eprintf "autarx: expected <tool> <project> — try 'autarx vendor --help'\n")
        2]
       [else
        (define tool-name (car positional))
        (define project (cadr positional))
        (define json? (hash-ref opts 'json #f))
        (define adapter (find-vendor-adapter tool-name))
        (cond
          [(not adapter)
           (eprintf "autarx: unknown vendor tool '~a' — try 'autarx vendor list'\n"
                    tool-name)
           2]
          [(not (or (file-exists? project) (directory-exists? project)))
           (eprintf "autarx: project not found: ~a\n" project)
           2]
          [else
           (define explicit-exe (hash-ref opts 'exe #f))
           (cond
             [(and explicit-exe (not (file-exists? explicit-exe)))
              (eprintf "autarx: --exe not found: ~a\n" explicit-exe)
              2]
             [else
              (define tool
                (or (and explicit-exe
                         (vendor-tool (vendor-adapter-name adapter) explicit-exe #f))
                    (detect-vendor adapter
                                   (λ (n) (getenv n))
                                   resolve-executable)))
              (cond
                [(not tool)
                 (eprintf "autarx: ~a not detected — point --exe at the tool executable\n"
                          (vendor-adapter-display-name adapter))
                 2]
                [else
                 (define invocation
                   (build-invocation adapter tool project
                                     (hash-ref opts 'args #f)
                                     (hash-ref opts 'extra '())))
                 (define project-dir
                   (let-values ([(base _d _) (split-path
                                              (path->complete-path project))])
                     (if (path? base) (path->string base) ".")))
                 (define stamp (date-stamp-now))
                 (define raw-file
                   (string-append project-dir "/.autarx/vendor-"
                                  (vendor-adapter-name adapter) "-" stamp ".log"))
                 (define report
                   (execute-vendor-handoff tool invocation
                                           (hash-ref opts 'timeout 600)
                                           raw-file))
                 (if json?
                     (print-json (vendor-report-json report))
                     (render-vendor-report report))
                 (cond
                   [(vendor-report-timed-out? report) 2]
                   [(and (vendor-report-exit-code report)
                         (= (vendor-report-exit-code report) 0)
                         (= (vendor-report-error-count report) 0))
                    0]
                   [else 1])])])])])]))

(define (vendor-report-json report)
  (list (cons "tool" (vendor-report-tool report))
        (cons "executable" (vendor-report-executable report))
        (cons "arguments" (vendor-report-arguments report))
        (cons "exitCode" (or (vendor-report-exit-code report) 'null))
        (cons "timedOut" (vendor-report-timed-out? report))
        (cons "durationMilliseconds" (vendor-report-duration-milliseconds report))
        (cons "errorCount" (vendor-report-error-count report))
        (cons "warningCount" (vendor-report-warning-count report))
        (cons "diagnostics"
              (for/list ([d (in-list (vendor-report-diagnostics report))])
                (list (cons "severity" (vendor-diagnostic-severity d))
                      (cons "message" (vendor-diagnostic-message d)))))
        (cons "rawOutputFile" (vendor-report-raw-output-file report))))

(define (render-vendor-report report)
  (define adapter (find-vendor-adapter (vendor-report-tool report)))
  (out-ln (vendor-adapter-display-name adapter)
          " hand-off (relayed vendor result — not an autarx verdict)")
  (out-ln "  command: " (vendor-report-executable report) " "
          (vendor-report-arguments report))
  (out-ln "  exit: "
          (cond
            [(vendor-report-timed-out? report) "timeout"]
            [(vendor-report-exit-code report)
             (number->string (vendor-report-exit-code report))]
            [else "n/a"])
          " in " (number->string (vendor-report-duration-milliseconds report)) " ms")
  (out-ln "  diagnostics: " (number->string (vendor-report-error-count report))
          " error(s), " (number->string (vendor-report-warning-count report))
          " warning(s)")
  (define diagnostics (vendor-report-diagnostics report))
  (for ([d (in-list (take-up-to diagnostics 20))])
    (out-ln "    [" (vendor-diagnostic-severity d) "] "
            (vendor-diagnostic-message d)))
  (when (> (length diagnostics) 20)
    (out-ln "    … " (number->string (- (length diagnostics) 20))
            " more (see raw output)"))
  (out-ln "  raw output: " (vendor-report-raw-output-file report)))

(define (take-up-to lst n)
  (if (> (length lst) n) (take lst n) lst))

(define (date-stamp-now)
  (define d (seconds->date (current-seconds) 0))
  (format "~a~a~a-~a~a~a"
          (date-year d) (pad2 (date-month d)) (pad2 (date-day d))
          (pad2 (date-hour d)) (pad2 (date-minute d)) (pad2 (date-second d))))

(define (parse-vendor-validate args)
  (let loop ([args args] [positional '()] [opts (hash)])
    (cond
      [(null? args)
       (list (reverse positional) opts)]
      [(string=? (car args) "--json")
       (loop (cdr args) positional (hash-set opts 'json #t))]
      [(member (car args) '("--exe" "--args" "--timeout"))
       (define opt (substring (car args) 2))
       (if (null? (cdr args))
           (begin
             (eprintf "autarx: --~a requires a value\n" opt)
             #f)
           (let ([value (cadr args)]
                 [rest (cddr args)])
             (case opt
               [("timeout")
                (define n (string->number value))
                (if (or (not n) (not (positive? n)))
                    (begin
                      (eprintf
                       "autarx: --timeout requires a positive number of seconds\n")
                      #f)
                    (loop rest positional (hash-set opts 'timeout n)))]
               [else
                (loop rest positional (hash-set opts
                                               (string->symbol opt)
                                               value))])))]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx vendor --help'\n"
                (car args))
       #f]
      [else (loop (cdr args) (cons (car args) positional) opts)])))

;; ---------------------------------------------------------------- patch

(define (cmd-patch args)
  (cond
    [(null? args) (patch-usage 2)]
    [(member (car args) '("-h" "--help" "help")) (patch-usage 0)]
    [(string=? (car args) "plan") (patch-plan-cmd (cdr args))]
    [(string=? (car args) "apply") (patch-apply-cmd (cdr args))]
    [(string=? (car args) "undo") (patch-undo-cmd (cdr args))]
    [else
     (eprintf "autarx: unknown patch subcommand '~a' — try 'autarx patch --help'\n"
              (car args))
     2]))

(define (patch-usage exit-code)
  (displayln
   (string-append
    "autarx patch — reviewed ARXML edits (plan → diff → apply → undo)\n"
    "\n"
    "Usage:\n"
    "  autarx patch plan  <workspace> --file ops.json [--json]\n"
    "  autarx patch apply <workspace> --file ops.json [--json]\n"
    "  autarx patch undo  <workspace> [--json]\n"
    "\n"
    "ops.json:\n"
    "  { \"operations\": [\n"
    "    { \"op\": \"rename\", \"target\": \"/Pkg/Obj\", \"newName\": \"NewName\" },\n"
    "    { \"op\": \"set-parameter\", \"target\": \"/Pkg/Module\",\n"
    "      \"definition\": \"/Vendor/Module/Ctr/Param\", \"value\": \"2\" },\n"
    "    { \"op\": \"add-parameter\", \"target\": \"/Pkg/Module\",\n"
    "      \"definition\": \"/Vendor/Module/Ctr/NewParam\", \"value\": \"5\",\n"
    "      \"type\": \"numeric\" },\n"
    "    { \"op\": \"set-reference\", \"target\": \"/Pkg/Module\",\n"
    "      \"definition\": \"/Vendor/Module/Ctr/Ref\", \"value\": \"/Pkg/Other\" }\n"
    "  ] }\n"
    "\n"
    "Plan is read-only and returns the mandatory before/after semantic diff.\n"
    "Apply writes only changed files, keeps <file>.autarx-bak backups under\n"
    ".autarx/ and appends to .autarx/patch-history.jsonl for undo.\n"))
  exit-code)

(define (parse-op-args args)
  (let loop ([args args] [positional '()] [json? #f] [file #f])
    (cond
      [(null? args)
       (if (and file (= (length positional) 1))
           (list (car positional) file json?)
           (begin
             (eprintf
              "autarx: expected <workspace> --file <ops.json>\n")
             #f))]
      [(string=? (car args) "--json") (loop (cdr args) positional #t file)]
      [(string=? (car args) "--file")
       (if (null? (cdr args))
           (begin (eprintf "autarx: --file requires a value\n") #f)
           (loop (cddr args) positional json? (cadr args)))]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx patch --help'\n"
                (car args))
       #f]
      [else (loop (cdr args) (cons (car args) positional) json? file)])))

(define (load-op-set path)
  (cond
    [(not (file-exists? path))
     (eprintf "autarx: operations file not found: ~a\n" path)
     #f]
    [else
     (define parsed (parse-patch-op-set (file->string path)))
     (define errors (cdr parsed))
     (unless (null? errors)
       (for ([e (in-list errors)]) (eprintf "autarx: ~a\n" e)))
     (if (or (null? (car parsed)) (not (null? errors)))
         #f
         (car parsed))]))

(define (patch-provenance)
  (string-append "semantic patch by autarx " autarx-version
                 " (" (date->iso (seconds->date (current-seconds) 0)) ")"))

(define (plan-json plan)
  (list (cons "valid" (patch-plan-valid? plan))
        (cons "operations"
              (for/list ([r (in-list (patch-plan-operations plan))])
                (list (cons "index" (patch-op-result-index r))
                      (cons "op" (patch-op-result-op r))
                      (cons "target" (patch-op-result-target r))
                      (cons "ok" (patch-op-result-ok? r))
                      (cons "error" (or (patch-op-result-error r) 'null)))))
        (cons "affectedFiles" (patch-plan-affected-files plan))
        (cons "diff" (or (and (patch-plan-diff plan) (diff-json (patch-plan-diff plan)))
                         'null))))

(define (patch-plan-cmd args)
  (define parsed (parse-op-args args))
  (cond
    [(not parsed) 2]
    [else
     (define workspace (car parsed))
     (define ops-file (cadr parsed))
     (define json? (caddr parsed))
     (define ops (load-op-set ops-file))
     (cond
       [(not ops) 2]
       [else
        (define plan (plan-patch workspace ops (patch-provenance)))
        (if json?
            (print-json (plan-json plan))
            (begin
              (when (patch-plan-valid? plan)
                (define ok-count
                  (count-where patch-op-result-ok? (patch-plan-operations plan)))
                (out-ln "operations: " (number->string
                                        (length (patch-plan-operations plan)))
                        " (" (number->string ok-count) " ok, "
                        (number->string (- (length (patch-plan-operations plan))
                                           ok-count))
                        " failed)")
                (for ([r (in-list (patch-plan-operations plan))])
                  (if (patch-op-result-ok? r)
                      (out-ln "  [" (patch-op-result-op r) "] "
                              (patch-op-result-target r) " — ok")
                      (out-ln "  [" (patch-op-result-op r) "] "
                              (patch-op-result-target r) " — FAILED: "
                              (patch-op-result-error r))))
                (unless (patch-plan-valid? plan)
                  (out-ln "plan invalid — nothing will be applied"))
                (when (patch-plan-valid? plan)
                  (out-ln "")
                  (out-ln "planned semantic diff ("
                          (number->string
                           (length (patch-plan-affected-files plan)))
                          " file(s): "
                          (string-join (patch-plan-affected-files plan) ", ")
                          "):")
                  (render-plan-diff (patch-plan-diff plan))))))
        (if (patch-plan-valid? plan) 0 1)])]))

(define (render-plan-diff d)
  (define objects (workspace-diff-objects d))
  (define references (workspace-diff-references d))
  (if (and (null? objects) (null? references))
      (out-ln "  (no semantic differences — the operations are no-ops)")
      (begin
        (for ([c (in-list objects)])
          (define marker
            (case (object-change-change-type c)
              [(added) "+"] [(removed) "-"] [else "~"]))
          (out-ln "  " marker " " (or (object-change-element-type c) "?") " "
                  (object-change-absolute-path c))
          (for ([p (in-list (or (object-change-properties c) '()))])
            (out-ln "      " (property-change-path p) ": "
                    (or (property-change-before p) "(absent)") " → "
                    (or (property-change-after p) "(absent)"))))
        (for ([r (in-list references)])
          (define marker (if (eq? (reference-change-change-type r) 'added)
                             "+" "-"))
          (out-ln "  " marker " " (reference-change-kind r) " "
                  (reference-change-source-path r) " -> "
                  (reference-change-target-path r))))))

(define (count-where pred lst)
  (for/sum ([x (in-list lst)] #:when (pred x)) 1))

(define (patch-apply-cmd args)
  (define parsed (parse-op-args args))
  (cond
    [(not parsed) 2]
    [else
     (define workspace (car parsed))
     (define ops-file (cadr parsed))
     (define json? (caddr parsed))
     (define ops (load-op-set ops-file))
     (cond
       [(not ops) 2]
       [else
        (define plan (plan-patch workspace ops (patch-provenance)))
        (cond
          [(not (patch-plan-valid? plan))
           (if json?
               (print-json (plan-json plan))
               (begin
                 (for ([r (in-list (patch-plan-operations plan))])
                   (unless (patch-op-result-ok? r)
                     (eprintf "autarx: operation ~a (~a ~a) failed: ~a\n"
                              (patch-op-result-index r)
                              (patch-op-result-op r)
                              (patch-op-result-target r)
                              (patch-op-result-error r))))
                 (eprintf "autarx: nothing was written\n")))
           1]
          [else
           (define manifest
             (apply-patch workspace plan (patch-plan-temp-workspace plan)))
           (if json?
               (print-json
                (list (cons "applied" #t)
                      (cons "timestamp" (patch-manifest-timestamp manifest))
                      (cons "files"
                            (map patch-file-record-relative-path
                                 (patch-manifest-files manifest)))
                      (cons "operationCount" (patch-manifest-operation-count manifest))
                      (cons "diff" (diff-json (patch-plan-diff plan)))))
               (begin
                 (out-ln "applied "
                         (number->string (patch-manifest-operation-count manifest))
                         " operation(s) to "
                         (number->string (length (patch-manifest-files manifest)))
                         " file(s); backups kept as <file>.autarx-bak:")
                 (for ([f (in-list (patch-manifest-files manifest))])
                   (out-ln "  " (patch-file-record-relative-path f)))
                 (render-plan-diff (patch-plan-diff plan))))
           0])])]))

(define (patch-undo-cmd args)
  (let loop ([args args] [positional '()] [json? #f])
    (cond
      [(null? args)
       (cond
         [(not (= (length positional) 1))
          (eprintf "autarx: expected <workspace> — try 'autarx patch --help'\n")
          2]
         [else
          (define undone (undo-patch (car positional)))
          (cond
            [(not undone)
             (eprintf
              "autarx: nothing to undo (no patch history in .autarx/patch-history.jsonl)\n")
             1]
            [else
             (if json?
                 (print-json
                  (list (cons "undone" #t)
                        (cons "timestamp" (patch-manifest-timestamp undone))
                        (cons "files"
                              (map patch-file-record-relative-path
                                   (patch-manifest-files undone)))))
                 (begin
                   (out-ln "undid patch from " (patch-manifest-timestamp undone)
                           ", restored:")
                   (for ([f (in-list (patch-manifest-files undone))])
                     (out-ln "  " (patch-file-record-relative-path f)))))
             0])])]
      [(string=? (car args) "--json") (loop (cdr args) positional #t)]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx patch --help'\n"
                (car args))
       2]
      [else (loop (cdr args) (cons (car args) positional) json?)])))

;; ---------------------------------------------------------------- update

(define (cmd-update args)
  (define parsed (parse-update-args args))
  (cond
    [(not parsed) 2]
    [else (run-update parsed)]))

;; --feed keeps its old meaning (the manifest URL); a base URL without the
;; file name also works. Local file paths are gone: every feed is an
;; authenticated HTTPS signed wrapper now, and fetch-update-manifest
;; rejects anything else (the pre-0.3.1 checksum feed was the supply-chain
;; gap this retires — shared/spec/UPDATE.md).
(define (feed-overrides parsed)
  (define feed (hash-ref parsed 'feed #f))
  (if (not feed)
      (values #f #f)
      (let ([trimmed (string-trim feed "/" #:right? #t)])
        (if (string-suffix? trimmed ".json")
            (values #f trimmed)
            (values trimmed #f)))))

;; the apply leg lives in its own function: deep cond nesting here caused
;; real bracket bugs
(define (run-update parsed)
  (define check-only? (hash-ref parsed 'check #f))
  (define json? (hash-ref parsed 'json #f))
  (define-values (base override-url) (feed-overrides parsed))
  (define-values (platform architecture)
    (let ([raw (hash-ref parsed 'platform #f)])
      (if raw
          (values (string->symbol (car (string-split raw "-")))
                  (string->symbol (cadr (string-split raw "-"))))
          (values #f #f))))
  (define outcome
    (parameterize ([u:current-update-base-url base]
                   [u:current-update-manifest-url override-url])
      (u:check-for-update! autarx-version
                           #:platform platform
                           #:architecture architecture)))
  (define status (hash-ref outcome 'status))
  (cond
    [(string=? status "error")
     (eprintf "autarx: update check failed: ~a\n" (hash-ref outcome 'message))
     2]
    [(string=? status "up-to-date")
     (define latest (hash-ref outcome 'latestVersion))
     (when json?
       (print-json (list (cons "currentVersion" autarx-version)
                         (cons "latestVersion" latest)
                         (cons "updateAvailable" #f))))
     (unless json?
       (out-ln "autarx " autarx-version
               " is up to date (latest release: " latest ")."))
     0]
    [else
     (define latest (hash-ref outcome 'availableVersion))
     (cond
       [json?
        (print-json (list (cons "currentVersion" autarx-version)
                          (cons "latestVersion" latest)
                          (cons "updateAvailable" #t)))
        1]
       [check-only?
        (out-ln "update available: " latest " (current: " autarx-version
                ") — run 'autarx update' to apply.")
        1]
       [else (apply-update! parsed outcome)])]))

(define (apply-update! parsed outcome)
  (define latest (hash-ref outcome 'availableVersion))
  (out-ln "updating: " autarx-version " → " latest)
  (out-ln "  downloading and verifying…")
  (define zip-path
    (with-handlers ([exn:fail?
                     (λ (ex)
                       (eprintf "autarx: update download failed: ~a\n"
                                (exn-message ex))
                       #f)])
      (u:download-candidate! (build-path (find-system-path 'temp-dir)
                                         "autarx"))))
  (unless zip-path 2)
  ;; the payload's launcher carries the .exe suffix (Windows-only product)
  (define marker "autarx.exe")
  (define payload-root
    (with-handlers ([exn:fail?
                     (λ (ex)
                       (eprintf "autarx: update package rejected: ~a\n"
                                (exn-message ex))
                       #f)])
      (u:extract-verified zip-path (hash-ref outcome 'sha256) marker)))
  (define explicit-dir (hash-ref parsed 'install-dir #f))
  (define app-dir
    (if (and explicit-dir (> (string-length explicit-dir) 0))
        (string->path explicit-dir)
        (path-only (find-system-path 'run-file))))
  (if (not (and payload-root app-dir (directory-exists? app-dir)))
      (begin
        (when payload-root
          (eprintf "autarx: cannot locate install directory: ~a\n"
                   (if app-dir (path->string app-dir) "?")))
        2)
      (let ()
        (define replaced (u:apply-payload payload-root app-dir))
        (out-ln "  applied " (number->string replaced) " file(s) to "
                (path->string app-dir))
        (out-ln "autarx " latest " installed — restart to take effect.")
        (print-json
         (list (cons "currentVersion" autarx-version)
               (cons "latestVersion" latest)
               (cons "updateAvailable" #t)
               (cons "filesReplaced" replaced)
               (cons "installDirectory" (path->string app-dir))))
        0)))

(define (parse-update-args args)
  (let loop ([args args] [opts (hash)])
    (cond
      [(null? args) opts]
      [(string=? (car args) "--check") (loop (cdr args) (hash-set opts 'check #t))]
      [(string=? (car args) "--force") (loop (cdr args) (hash-set opts 'force #t))]
      [(string=? (car args) "--install-dir")
       (if (null? (cdr args))
           (begin
             (eprintf "autarx: --install-dir requires a value\n")
             #f)
           (loop (cddr args) (hash-set opts 'install-dir (cadr args))))]
      [(string=? (car args) "--json") (loop (cdr args) (hash-set opts 'json #t))]
      [(member (car args) '("--feed" "--kind" "--platform"))
       (define opt (substring (car args) 2))
       (if (null? (cdr args))
           (begin
             (case opt
               [("feed") (eprintf "autarx: --feed requires an HTTPS URL\n")]
               [("kind") (eprintf "autarx: --kind must be cli\n")]
               [("platform")
                (eprintf "autarx: --platform requires a value (e.g. windows-x64)\n")])
             #f)
           (let ([value (cadr args)])
             (if (valid-update-option? opt value)
                 (loop (cddr args) (hash-set opts (string->symbol opt) value))
                 #f)))]
      [(string-prefix? (car args) "-")
       (eprintf "autarx: unknown option '~a' — try 'autarx update --help'\n"
                (car args))
       #f]
      [else
       (eprintf "autarx: update takes no positional arguments\n")
       #f])))

;; Answers #f on a bad value (after the specific complaint); the caller
;; aborts the parse (the pre-rivet parser printed but kept parsing).
(define (valid-update-option? opt value)
  ;; eprintf returns void — truthy — so rejection must return #f itself
  (define (reject message)
    (eprintf "~a\n" message)
    #f)
  (case opt
    [("kind")
     ;; the signed feed covers the CLI only; the workbench updates itself
     ;; through its own feed (shared/spec/UPDATE.md)
     (if (string=? value "cli")
         #t
         (reject "autarx: --kind must be cli (the gui ships its own feed)"))]
    [("platform")
     ;; Windows-only product (issue #56): the feed carries windows-x64
     ;; exclusively, so no other spelling can ever select an artifact
     (if (regexp-match? #rx"^windows-x64$" value)
         #t
         (reject "autarx: --platform must be windows-x64"))]
    [else #t]))

;; ---------------------------------------------------------------- info / modules / validate

(define (with-loaded-file args action)
  (let loop ([args args] [file #f] [json? #f])
    (cond
      [(null? args)
       (cond
         [(and (not file) (not json?))
          (eprintf "autarx: input file required — try 'autarx --help'\n")
          2]
         [(not file) 2]
         [else (action file json?)])]
      [(string=? (car args) "--json") (loop (cdr args) file #t)]
      [(and (string-prefix? (car args) "-")
            (> (string-length (car args)) 1))
       (eprintf "autarx: unknown option '~a' — try 'autarx --help'\n" (car args))
       2]
      [file
       (eprintf "autarx: exactly one input file expected\n")
       2]
      [else (loop (cdr args) (car args) json?)])))

(define (load-single-file file)
  (cond
    [(not (or (file-exists? file) (directory-exists? file)))
     (eprintf "autarx: file not found: ~a\n" file)
     #f]
    [(directory-exists? file)
     (eprintf "autarx: directory not found: ~a\n"
              (let-values ([(base _d _) (split-path (path->complete-path file))])
                (if (path? base) (path->string base) file)))
     #f]
    [else
     (with-handlers ([exn:fail:autarx:parse?
                      (λ (ex)
                        (define location
                          (if (> (exn:fail:autarx:parse-line ex) 0)
                              (format " (line ~a)" (exn:fail:autarx:parse-line ex))
                              ""))
                        (eprintf "autarx: invalid ARXML~a: ~a\n"
                                 location (exn-message ex))
                        #f)]
                     [exn:fail:filesystem?
                      (λ (ex)
                        (eprintf "autarx: cannot read ~a: ~a\n" file (exn-message ex))
                        #f)])
       (cons (parse-arxml-file file) (current-inexact-milliseconds)))]))

(define (cmd-info args)
  (with-loaded-file
   args
   (λ (file json?)
     (define t0 (current-inexact-milliseconds))
     (define loaded (load-single-file file))
     (cond
       [(not loaded) 2]
       [else
        (define root (car loaded))
        (define modules (read-modules root))
        (define elapsed (inexact->exact
                         (round (- (cdr loaded) t0))))
        (define size (file-size (string->path file)))
        (define element-count
          (let loop ([e root])
            (add1 (for/sum ([c (in-list (arxml-element-children e))]) (loop c)))))
        (if json?
            (print-json
             (list (cons "file" file)
                   (cons "sizeBytes" size)
                   (cons "elementCount" element-count)
                   (cons "moduleCount" (length modules))
                   (cons "modules" (map ecuc-module-short-name modules))
                   (cons "elapsedMs" elapsed)))
            (begin
              (out-ln "file            " file)
              (out-ln "size            " (fmt-n0 size) " B")
              (out-ln "elements        " (fmt-n0 element-count))
              (out-ln "ecuc modules    " (number->string (length modules))
                      (modules-suffix modules))
              (out-ln "parsed in       " (number->string elapsed) " ms")))
        0]))))

(define (modules-suffix modules)
  (if (null? modules)
      ""
      (string-append " ("
                     (string-join (map ecuc-module-short-name modules) ", ")
                     ")")))

(define (cmd-modules args)
  (with-loaded-file
   args
   (λ (file json?)
     (define loaded (load-single-file file))
     (cond
       [(not loaded) 2]
       [else
        (define modules (read-modules (car loaded)))
        (if json?
            (print-json
             (for/list ([m (in-list modules)])
               (list (cons "shortName" (ecuc-module-short-name m))
                     (cons "definitionRef" (or (ecuc-module-definition-ref m) 'null))
                     (cons "containers" (module-total-containers m))
                     (cons "parameters" (module-total-parameters m)))))
            (for ([m (in-list modules)])
              (out-ln (pad-left-str (ecuc-module-short-name m) 20)
                      (pad-left-str
                       (or (ecuc-module-definition-ref m) "(no definition-ref)") 40)
                      " containers=" (number->string (module-total-containers m))
                      " parameters=" (number->string (module-total-parameters m)))))
        0]))))

(define (cmd-validate args)
  (with-loaded-file
   args
   (λ (file json?)
     (define loaded (load-single-file file))
     (cond
       [(not loaded) 2]
       [else
        (define diagnostics (validate-modules (read-modules (car loaded))))
        (define errors
          (count-where (λ (d) (eq? (diagnostic-severity d) 'error)) diagnostics))
        (define warnings
          (count-where (λ (d) (eq? (diagnostic-severity d) 'warning)) diagnostics))
        (if json?
            (print-json
             (list (cons "errors" errors)
                   (cons "warnings" warnings)
                   (cons "diagnostics"
                         (for/list ([d (in-list diagnostics)])
                           (list (cons "code" (diagnostic-code d))
                                 (cons "severity"
                                       (if (eq? (diagnostic-severity d) 'error)
                                           "error" "warning"))
                                 (cons "message" (diagnostic-message d))
                                 (cons "path" (diagnostic-path d)))))))
            (begin
              (for ([d (in-list diagnostics)])
                (out-ln (pad-left-str
                         (string-upcase (symbol->string (diagnostic-severity d))) 7)
                        " " (diagnostic-code d) " " (diagnostic-path d) ": "
                        (diagnostic-message d)))
              (out-ln (number->string errors) " error(s), "
                      (number->string warnings) " warning(s)")))
        (if (> errors 0) 1 0)]))))

;; ---------------------------------------------------------------- mcp

(define (mcp-serve)
  ((dynamic-require 'autarx/mcp 'serve) autarx-version))


;; --cluster resolution: only the clusters list is replaced (an empty
;; projection when the model has none for it); frames/pdus/orphans stay
;; whole-model. Returns the filtered model, or 'error after reporting.
(define (filter-comm-cluster model ws cluster-name)
  (define resolution (resolve-object ws cluster-name))
  (cond
    [(eq? (resolution-status resolution) 'ambiguous)
     (eprintf "autarx: '~a' is ambiguous, ~a objects match:\n"
              cluster-name (length (resolution-candidates resolution)))
     (for ([c (in-list (resolution-candidates resolution))])
       (eprintf "  ~a\n" (semantic-object-absolute-path c)))
     'error]
    [else
     (define cluster-obj
       (case (resolution-status resolution)
         [(found) (resolution-object resolution)]
         [else #f]))
     (if (not (and cluster-obj
                   (eq? (semantic-object-kind cluster-obj)
                        'communication-cluster)))
         (begin
           (eprintf "autarx: no communication cluster matches '~a'\n" cluster-name)
           'error)
         (let* ([path (semantic-object-absolute-path cluster-obj)]
                [existing
                 (for/or ([c (in-list (communication-model-clusters model))])
                   (and (string=? (cluster-projection-cluster-path c) path) c))])
           (struct-copy communication-model model
                        [clusters (list (or existing
                                            (cluster-projection path '() '())))])))]))
