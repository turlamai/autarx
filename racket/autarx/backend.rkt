#lang racket/base

;; Rivet backend entry — the GUI host's data channel. This surface is the
;; R7 addition (the CLI/MCP link the domain core directly); it exposes the
;; read-heavy queries the workbench renders plus the reviewed patch flow.

(require racket/string
         rivet/backend
         "app-update.rkt"
         "index.rkt"
         "classify.rkt"
         "diff.rkt"
         "impact.rkt"
         "comm.rkt"
         "validate.rkt"
         "patch.rkt"
         "ecuc.rkt"
         "arxml.rkt"
         "rivet-schema.rkt")

(provide start
         start-stdio)

(define current-index (box #f))

;; long-operation progress: the first consumer of the rivet progress event
;; (workspace indexing on large deliveries is a seconds-scale operation)
(define-event progress)

(define (require-index)
  (or (unbox current-index)
      (error 'autarx "workspace is not open")))

(define (kind-string kind) (hash-ref kind->json kind))

(define-rpc (open_workspace [path : String] : WorkspaceSummary)
  (progress "indexing 0%")
  (define index (build-workspace-index path))
  (set-box! current-index index)
  (progress "indexing 100%")
  (summary->dto index))

(define-rpc (close_workspace : Bool)
  (set-box! current-index #f)
  #t)

(define-rpc (workspace_summary : WorkspaceSummary)
  (summary->dto (require-index)))

(define-rpc (find_objects [pattern : String] : (List SemanticObjectDto))
  (objects->dtos (find-by-name (require-index) pattern)))

(define-rpc (list_objects [kind : String] : (List SemanticObjectDto))
  (define index (require-index))
  (define wanted
    (for/list ([(k _) (in-hash kind->json)]) k))
  (define keep
    (if (string=? kind "all")
        (λ (o) #t)
        (λ (o) (string=? (kind-string (semantic-object-kind o)) kind))))
  (objects->dtos
   (filter keep (workspace-index-objects index))))

(define-rpc (get_refs [name-or-path : String] : (List ReferenceDto))
  (define index (require-index))
  (define resolution (resolve-object index name-or-path))
  (case (resolution-status resolution)
    [(found)
     (define path (semantic-object-absolute-path (resolution-object resolution)))
     (append (map reference->dto (outgoing-of index path))
             (map reference->dto (incoming-of index path)))]
    [else '()]))

(define-rpc (trace_from [name-or-path : String]
                        [depth : Int64]
                        : TraceDto)
  (define index (require-index))
  (define resolution (resolve-object index name-or-path))
  (case (resolution-status resolution)
    [(found)
     (define path (semantic-object-absolute-path (resolution-object resolution)))
     (define result (trace index path 'both depth))
     (trace->dto result)]
    [else (trace-result->empty name-or-path depth)]))

(define-rpc (list_ecus : (List SemanticObjectDto))
  (define index (require-index))
  (objects->dtos
   (filter (λ (o) (eq? (semantic-object-kind o) 'ecu))
           (workspace-index-objects index))))

(define-rpc (unresolved_references : (List ReferenceDto))
  (map reference->dto
       (filter (compose not arx-reference-resolved)
               (workspace-index-references (require-index)))))

(define-rpc (diff_workspaces [before : String]
                             [after : String]
                             : DiffDto)
  (progress "diffing 0%")
  (define d
    (compare-workspaces (build-workspace-index before)
                        (build-workspace-index after)))
  (progress "diffing 100%")
  (diff->dto d))

(define-rpc (impact_for_ecu [before : String]
                            [after : String]
                            [ecu-name : String]
                            : DiffDto)
  (define before-idx (build-workspace-index before))
  (define after-idx (build-workspace-index after))
  (define after-r (resolve-object after-idx ecu-name))
  (define before-r (resolve-object before-idx ecu-name))
  (define ecu-object
    (cond
      [(eq? (resolution-status after-r) 'found) (resolution-object after-r)]
      [(eq? (resolution-status before-r) 'found) (resolution-object before-r)]
      [else (error 'impact_for_ecu
                   "no workspace object matches '~a' in either delivery"
                   ecu-name)]))
  (define report
    (analyze-impact before-idx after-idx
                    (semantic-object-absolute-path ecu-object)
                    (and (eq? (resolution-status after-r) 'not-found)
                         (eq? (resolution-status before-r) 'found))
                    (compare-workspaces before-idx after-idx #f)
                    #f))
  (impact->dto report))

(define-rpc (communication : CommunicationDto)
  (comm->dto (build-communication (require-index))))

(define-rpc (validate_workspace : (List String))
  ;; structural checks over every ECUC module in the open workspace
  (define index (require-index))
  (for/list ([d (in-list (workspace-index-documents index))])
    (define root (parse-arxml-file (workspace-document-file-path d)))
    (for/list ([diag (in-list (validate-modules (read-modules root)))])
      (format "~a ~a: ~a"
              (diagnostic-code diag)
              (diagnostic-path diag)
              (diagnostic-message diag)))))

;; reviewed patch flow: plan is read-only, apply keeps backups + history
(define-rpc (patch_plan [workspace : String]
                        [ops-json : String]
                        : DiffDto)
  (define parsed (parse-patch-op-set ops-json))
  (unless (null? (cdr parsed))
    (error 'patch_plan "~a" (string-join (cdr parsed) "; ")))
  (define plan (plan-patch workspace (car parsed)))
  (unless (patch-plan-valid? plan)
    (error 'patch_plan "plan invalid — nothing would be written"))
  (diff->dto (patch-plan-diff plan)))

(define-rpc (patch_apply [workspace : String]
                         [ops-json : String]
                         : DiffDto)
  (define parsed (parse-patch-op-set ops-json))
  (unless (null? (cdr parsed))
    (error 'patch_apply "~a" (string-join (cdr parsed) "; ")))
  (define plan (plan-patch workspace (car parsed)))
  (unless (patch-plan-valid? plan)
    (error 'patch_apply "plan invalid — nothing was written"))
  (apply-patch workspace plan (patch-plan-temp-workspace plan))
  (diff->dto (patch-plan-diff plan)))

;; ------------------------------------------------------------ online update
;; The taskly family shape: this backend verifies and downloads the signed
;; workbench artifact (update-app-manifest.json); the Windows host owns
;; installation and the silent 4-hour throttle.

(define (update-check->record result)
  (define (opt key) (nullable (hash-ref result key #f)))
  (UpdateCheck
   (hash-ref result 'status "error")
   (opt 'message)
   (hash-ref result 'currentVersion (workbench-version))
   (opt 'availableVersion)
   (opt 'build)
   (opt 'publishedAt)
   (opt 'installer)
   (opt 'sizeBytes)))

;; Never raises: network/manifest failures surface as status "error" so a
;; headless check can't take the host down with it.
(define-rpc (check_updates : UpdateCheck)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          ;; the error arm already IS the failure path — if even the
          ;; version lookup raises here, report an empty current version
          ;; rather than letting a second error escape the handler
          (UpdateCheck "error" (nullable (exn-message e))
                       (or (with-handlers ([exn:fail? (lambda (_) #f)])
                             (workbench-version))
                           "")
                       (void) (void) (void) (void) (void)))])
    (update-check->record (perform-check!))))

;; Runs on a backend worker thread; the host follows progress via
;; update_state. Never raises: failures surface through the state's phase.
(define-rpc (start_download : Void)
  (with-handlers
      ([exn:fail? (lambda (e) (set-update-error! (exn-message e)))])
    (start-download!))
  (void))

(define-rpc (update_state : UpdateState)
  (define s (update-state-snapshot))
  (UpdateState
   (hash-ref s 'phase "idle")
   (hash-ref s 'percent 0)
   (nullable (hash-ref s 'message #f))
   (nullable (hash-ref s 'downloadedPath #f))
   (nullable (hash-ref s 'availableVersion #f))))

;; ---------------------------------------------------------------- mapping

(define (summary->dto index)
  (define s (summarize index))
  (WorkspaceSummary
   (workspace-index-source-path index)
   (workspace-summary-file-count s)
   (workspace-summary-identifiable-count s)
   (workspace-summary-package-count s)
   (workspace-summary-reference-count s)
   (workspace-summary-unresolved-reference-count s)
   (workspace-summary-duplicate-path-count s)
   (workspace-summary-file-error-count s)
   (workspace-summary-autosar-release s)
   (workspace-summary-mixed-schema s)))

(define (object->dto o)
  (define index (require-index))
  (SemanticObjectDto
   (semantic-object-short-name o)
   (semantic-object-element-type o)
   (kind-string (semantic-object-kind o))
   (semantic-object-absolute-path o)
   (semantic-object-source-file o)
   (count-where (λ (r) (and (string=? (arx-reference-source-path r)
                                      (semantic-object-absolute-path o))
                            (not (arx-reference-resolved r))))
                (workspace-index-references index))))

(define (objects->dtos objs) (map object->dto objs))

(define (reference->dto r)
  (ReferenceDto
   (arx-reference-kind r)
   (arx-reference-source-path r)
   (arx-reference-source-element-path r)
   (arx-reference-target-path r)
   (arx-reference-resolved r)))

(define (trace->dto result)
  (TraceDto
   (trace-result-root result)
   (trace-result-max-depth result)
   (map trace-node-path (trace-result-nodes result))
   (map (λ (e)
          (ReferenceDto
           (trace-edge-kind e)
           (trace-edge-source-path e)
           (trace-edge-source-path e)
           (trace-edge-target-path e)
           #t))
        (trace-result-edges result))))

(define (trace-result->empty root depth)
  (TraceDto root depth '() '()))

(define (change->dto c)
  (ObjectChangeDto
   (case (object-change-change-type c)
     [(added) "added"] [(removed) "removed"] [else "modified"])
   (object-change-short-name c)
   (kind-string (object-change-kind c))
   (object-change-absolute-path c)
   (format "~a" (or (object-change-element-type c) "?"))))

(define (diff->dto d)
  (DiffDto
   (workspace-diff-empty? d)
   (map change->dto (workspace-diff-objects d))
   (length (workspace-diff-references d))))

(define (impact->dto report)
  (DiffDto
   (= (impact-report-relevant-count report) 0)
   (map (λ (f)
          (ObjectChangeDto
           (if (eq? (impact-finding-severity f) 'breaking)
               "breaking" "info")
           (impact-finding-rule f)
           (impact-finding-object-path f)
           (impact-finding-detail f)
           ""))
        (impact-report-findings report))
   (impact-report-relevant-count report)))

(define (comm->dto m)
  (CommunicationDto
   (map (λ (c)
          (ClusterDto
           (cluster-projection-cluster-path c)
           (cluster-projection-connected-ecus c)
           (cluster-projection-frame-paths c)))
        (communication-model-clusters m))
   (communication-model-orphan-frames m)
   (communication-model-orphan-pdus m)
   (communication-model-orphan-signals m)))

(define (count-where pred lst)
  (for/sum ([x (in-list lst)] #:when (pred x)) 1))

;; Native embedded hosts pass anonymous pipe file descriptors here.
(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))

;; The managed development host speaks RVT1 over stdin/stdout.
(define (start-stdio)
  (serve (current-input-port) (current-output-port)))

(module+ main
  (start-stdio))
