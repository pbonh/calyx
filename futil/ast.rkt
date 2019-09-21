#lang racket/base

(require racket/dict
         racket/bool
         racket/sequence
         racket/list
         racket/pretty
         racket/format
         racket/match
         racket/contract
         racket/set
         threading
         graph
         "state-dict.rkt"
         "component.rkt"
         "port.rkt"
         "util.rkt")

(provide (struct-out par-comp)
         (struct-out seq-comp)
         (struct-out deact-stmt)
         (struct-out act-stmt)
         (struct-out if-stmt)
         (struct-out ifen-stmt)
         (struct-out while-stmt)
         (struct-out mem-print)
         ;; (struct-out val-print)
         (struct-out ast-tuple)
         (struct-out mem-tuple)
         display-mem
         blank-state
         input-state
         compute)

;; type of statements
(define-struct/contract par-comp
  ([stmts (and/c list? (not/c empty?))])
  #:transparent)

(define-struct/contract seq-comp
  ([stmts list?])
  #:transparent)

(define-struct/contract deact-stmt
  ([mods (listof symbol?)])
  #:transparent)

(define-struct/contract act-stmt
  ([mods (listof symbol?)])
  #:transparent)

(define-struct/contract if-stmt
  ([condition pair?]
   [tbranch any/c]
   [fbranch any/c])
  #:transparent)

(define-struct/contract ifen-stmt
  ([condition pair?]
   [tbranch any/c]
   [fbranch any/c])
  #:transparent)

(define-struct/contract while-stmt
  ([condition pair?]
   [body any/c])
  #:transparent)

(define-struct/contract mem-print
  ([var any/c])
  #:transparent)

;; a hash union that tries to make overlapping keys non-false
;;   if v1 or v2 is #f, choose non-false option
;;   otherwise, if both v1 and v2 have values, choose v2
(define (save-state-union h1 h2)
  (state-union
   h1
   h2
   #:combine (lambda (v1 v2)
               (cond [(and v1 v2) v2]
                     [else (xor v1 v2)]))))

;; given a symbol representing the name of a value, and a ast-tuple
;; display the memory
(define (display-mem sym tup)
  (define (compare a b)
    (cond [(and (empty? a)
                (empty? b))
           #f]
          [(and (list? a)
                (list? b)
                (= (length a) (length b)))
           (if (= (car a) (car b))
               (compare (cdr a) (cdr b))
               (< (car a) (car b)))]
          [(and (number? a) (number? b))
           (< a b)]
          [else (error 'display-mem "Couldn't compare ~v and ~v" a b)]))

  (let* ([val (mem-tuple-value (dict-ref (ast-tuple-memory tup) sym))]
         [out (if (dict? val)
                  (sort (dict->list val)
                        (lambda (x y) (compare (car x) (car y))))
                  val)])
    (if (list? out)
        (for-each (lambda (x)
                    (display
                     (with-handlers ([exn:fail:contract?
                                      (lambda (e) "-nan")])
                       (real->decimal-string
                        (exact->inexact (cdr x))
                        4)))
                    (display "\n"))
                  out)
        (display out))))

;; create an empty state for the given component
(define (blank-state comp)
  (define sub-outs
    (apply append
           (dict-map
            (component-submods comp)
            (lambda (name sc)
              (map (lambda (p)
                     `(,name . ,(port-name p)))
                   (component-outs sc))))))
  (define comp-outs
    (map (lambda (p)
           `(,(port-name p) . inf#))
         (component-outs comp)))
  (state-dict
   (map (lambda (x)
          `(,x . #f))
        (append sub-outs comp-outs))))

;; create a state-like hash with only the inputs in the list
(define (input-state lst)
  (state-dict
   (map (match-lambda
          [(cons name val) `((,name . inf#) . ,val)]
          [_ (error "Expected list of tuples")])
        lst)))

;; takes comp, inputs to a submodule named 'name and renames them
;; to the ports of 'name that the inputs are connected to
(define (transform comp inputs name)
  (if (findf (lambda (x) (equal? name (port-name x))) (component-ins comp))
      ; if name is an input, (((in . inf#) . v) ...) -> ((in . inf#) . v)
      (state-dict `(((,name . inf#) . ,(dict-ref inputs `(,name . inf#)))))
      ; else name is not an input
      (begin
        (let* ([sub (get-submod! comp name)]
               [ins (map port-name (component-ins sub))])  ; XXX: deal with port widths
          (state-dict
           (map (lambda (in)
                  (define neighs
                    (~> (component-transpose comp)
                        (in-neighbors _ `(,name . ,in))
                        sequence->list))
                  (define filt-neighs-vals
                    (filter-map (lambda (x)
                                  (match (dict-ref inputs x)
                                    [(blocked dirt clean) clean]
                                    [v v]))
                                neighs))
                  (define neighs-val
                    (match filt-neighs-vals
                      [(list) #f]
                      [(list x) x]
                      [x (error
                          'transform
                          "Overlapping values in ~v! (~v @ ~v)\n ~v\ncontext: ~v"
                          (component-name comp)
                          name in x
                          (filter-map
                           (lambda (x)
                             (match (dict-ref inputs x)
                               [(blocked _ _) #f]
                               [#f #f]
                               [_ x]))
                           neighs))]))
                  `((,name . ,in) . ,neighs-val))
                ins))))))

; (submod -> mem-tuple) hash
; mem-tuple = (value * (submod -> mem-tuple) hash)
(struct mem-tuple (value sub-mem) #:transparent)
(define (empty-mem-tuple) (mem-tuple #f (empty-state)))

;; given a subcomponent (comp name) a state and memory,
;; run subcomponents proc with state and memory and
;; return updated state and memory
(define (submod-compute comp name state mem-tup inputs)
  (define trans (transform comp state name))
  (debug "inputs: " trans)
  (define inputs-p
    (state-dict
     (filter (lambda (pr)
               (equal? (caar pr) name))
             (dict->list inputs))))
  (define trans-p
    (save-state-union trans inputs-p))
  ;; trans is of the form (((sub . port) . val) ...)
  ;; change to ((port . val) ...)
  (define in-vals
    (~> (dict-map trans-p
                  (lambda (k v)
                    (define v-p
                      (match v
                        [(blocked dirt clean) clean]
                        [_ v]))
                    `(,(cdr k) . ,v-p)))
        state-dict))

  ;; add sub-memory and memory value to in-vals
  (define in-vals-p (dict-set* in-vals
                               'sub-mem# (mem-tuple-sub-mem mem-tup)
                               'mem-val# (mem-tuple-value mem-tup)))

  (let* ([sub (get-submod! comp name)]
         [proc (component-proc sub)]
         [mem-proc (component-memory-proc sub)]
         [trans-res (proc in-vals-p)]
         [sub-mem-p (dict-ref trans-res 'sub-mem#
                              (empty-state))]
         [trans-wo-mem (dict-remove trans-res 'sub-mem#)]
         [value-p (mem-proc (mem-tuple-value mem-tup)
                            (save-state-union in-vals trans-wo-mem))]
         [mem-tup-p (mem-tuple value-p sub-mem-p)])
    (values
     (state-dict
      (dict-map trans-wo-mem
                (lambda (k v) `((,name . ,k) . ,v))))
     mem-tup-p)))

;; syntax for special 3-branch if
;; cond = 0  -> tbranch
;; cond = 1  -> fbranch
;; cond = #f -> disbranch
(define-syntax-rule (if-valued condition tbranch fbranch disbranch)
  (if condition
      (if (not (equal? condition 0))
          tbranch
          fbranch)
      disbranch))

;; main structure that keeps track of everything in the computation
(struct ast-tuple (inputs inactive state memory) #:transparent)

(define toplevel-name (make-parameter #f))
(define save-memory? (make-parameter #f))

(define (compute-step comp tup)
  (debug "compute-step " (ast-tuple-state tup))
  (debug "memory: " (ast-tuple-memory tup))
  (debug "inactives mods: " (ast-tuple-inactive tup))

  ;; sets the value of every key in [lst] to [#f]
  (define (filt tup lst)
    (define state (ast-tuple-state tup))
    (struct-copy ast-tuple tup
                 [state
                  (state-dict
                   (dict-map state
                             (lambda (k v)
                               (if (member (car k) lst)
                                   `(,k . #f)
                                   `(,k . ,v)))))]))

  ;; algorithm that iteratively goes through a list of modules to calculate
  ;; the new state. Does this with a worklist like approach
  (define (worklist tup todo iter)
    (debug "worklist todo: " todo)
    (when (> iter 100)
      (error
       'worklist
       "Executed worklist too many times! There's probably an infinite loop."))
    (cond
      [(set-empty? todo) tup]
      [else
       (match-define (ast-tuple inputs inactive unfilt-state memory) tup)
       ;; filter inactive modules from the state
       (define state (ast-tuple-state (filt tup inactive)))

       (struct result (state todo))
       (~>
        (set-subtract todo (list->set inactive))
        set->list
        (map (lambda (name)
               (match-let*-values
                   ([(mem-tup) (dict-ref memory name empty-mem-tuple)]
                    [(dbg1) (debug "---- " name)]
                    [(outs mem-tup-p)
                     (submod-compute comp name state mem-tup inputs)]
                    [(outs-p)
                     (if (= iter 0)
                         (state-map
                          outs
                          (lambda (k v)
                            (define v-p (if (blocked? v)
                                            (blocked-clean v)
                                            v))
                            `(,k . ,v-p)))
                         outs)]
                    [(dbg2) (debug "result: " outs-p)]
                    [(acc-todo-p)
                     (~> outs-p
                         dict->list
                         ;; filter out all blocked values
                         (filter-not (lambda (x)
                                       (blocked? (cdr x))) _)
                         ;; get neighbors
                         (filter-map
                          (lambda (x)
                            (if (has-vertex? (component-graph comp) (car x))
                                (in-neighbors (component-graph comp) (car x))
                                #f))
                          _)
                         ;; convert to list
                         (map sequence->list _)
                         ;; flatten
                         (apply append _)
                         ;; remove empty lists if there are any
                         (filter-not empty? _)
                         ;; remove port names
                         (map car _)
                         (debug "todo-p: " _)
                         ;; back to a set
                         list->set)])
                 (result outs-p acc-todo-p)))
             _)
        (foldl (lambda (res acc)
                 (match-let ([(result res-st res-todo) res]
                             [(result acc-st acc-todo) acc])
                   (result
                    (save-state-union acc-st res-st)
                    (set-union res-todo acc-todo))))
               (result state (set))
               _)
        (match-define (result res-state res-todo) _))

       (worklist (filt (struct-copy ast-tuple tup
                                    [state res-state])
                       inactive)
                 res-todo
                 (add1 iter))]))

  (define (commit-memory tup order)
    (debug "commit state: " (ast-tuple-state tup))
    (match-define (ast-tuple inputs inactive unfilt-state memory) tup)
    (define state (ast-tuple-state (filt tup inactive)))
    (foldl (lambda (name acc)
             (cond [(member name inactive) acc]
                   [else
                    (debug "commit memory for " name)
                    (let*-values
                        ([(mem-tup) (dict-ref (ast-tuple-memory acc)
                                              name
                                              empty-mem-tuple)]
                         [(_ mem-tup-p)
                          (submod-compute comp name state mem-tup inputs)])
                      (struct-copy ast-tuple acc
                                   [memory
                                    (dict-set (ast-tuple-memory acc)
                                              name
                                              mem-tup-p)]))]))
           tup
           order))

  (define order (dict-keys (component-submods comp)))

  ;; stabilize state without saving memory
  (define res
    (worklist tup (list->set order) 0))

  ;; if toplevel, do a single pass saving memory
  (define res2
    (if (save-memory?)
        (commit-memory res order)
        res))

    (values
   (ast-tuple-state res2)
   (ast-tuple-memory res2)))

(define (check-condition condition tup)
  (match-define (ast-tuple inputs inactive state _) tup)
  (define state-p (save-state-union inputs state))
  (define filt-state-p
    (state-dict
     (dict-map state-p
               (lambda (k v)
                 (if (member (car k) inactive)
                     `(,k . #f)
                     `(,k . ,v))))))
  (dict-ref filt-state-p condition))

;; XXX don't delete this, I think I will need this to do par-comp correctly
;; (define (ast-active-mods comp ast)
;;   (match ast
;;     [(par-comp stmts)
;;      (apply append
;;             (map (lambda (x) (ast-active-mods comp x))))]
;;     [(seq-comp stmts)
;;      (apply append
;;             (map (lambda (x) (ast-active-mods comp x))))]
;;     [(deact-stmt mods)
;;      (filter-not (lambda (x) (member x mods))
;;                  (dict-keys (component-submods comp)))]
;;     [(act-stmt mods) mods]
;;     [(if-stmt _ tbranch fbranch)
;;      (append (ast-active-mods comp tbranch) (ast-active-mods comp fbranch))]
;;     [(ifen-stmt _ tbranch fbranch)
;;      (append (ast-active-mods comp tbranch) (ast-active-mods comp fbranch))]
;;     [(while-stmt _ body)
;;      (ast-active-mods comp body)]))

(define (ast-step comp tup ast #:hook [callback void])
  (match-define (ast-tuple inputs inactive state memory) tup)
  (debug "(open ast-step " ast)
  (define result
    (match ast
      [(par-comp stmts)
       (ast-step comp tup (seq-comp stmts) #:hook callback)
       ;; (define (merge-tup tup1 tup2)
       ;;   (match-let ([(ast-tuple ins-1 inact-1 st-1 mem-1)
       ;;                tup1]
       ;;               [(ast-tuple ins-2 inact-2 st-2 mem-2)
       ;;                tup2])
       ;;     (ast-tuple
       ;;      inputs
       ;;      (remove-duplicates (append inact-1 inact-2))
       ;;      (merge-state st-1 st-2)
       ;;      mem-1 ;; XXX fix this
       ;;      )))
       ;; (foldl merge-tup
       ;;        (struct-copy ast-tuple tup
       ;;                     [inactive '()]
       ;;                     [state (empty-state)]
       ;;                     [memory (empty-state)])
       ;;        (map (lambda (s) (ast-step comp tup s #:hook callback)) stmts))
       ]
      [(seq-comp stmts)
       (struct-copy ast-tuple
                    (foldl (lambda (s acc)
                             (define acc-p
                               (struct-copy ast-tuple
                                            acc
                                            [inactive (ast-tuple-inactive tup)]))
                             (ast-step comp acc-p s #:hook callback))
                           tup
                           stmts)
                    [inactive (ast-tuple-inactive tup)])]
      [(deact-stmt mods) ; compute step with this list of inactive modules
       (let*-values ([(tup-p)
                      (struct-copy ast-tuple tup
                                   [inactive (~> (append inactive mods)
                                                 remove-duplicates)])]
                     [(st mem)
                      (if (equal? (toplevel-name) (component-name comp))
                          (parameterize ([save-memory? #t])
                            (compute-step comp tup-p))
                          (compute-step comp tup-p))]
                     [(dbg)
                      (debug "ast-step memory: " mem)]
                     [(call) (callback (struct-copy ast-tuple tup-p
                                                    [state st]
                                                    [memory mem]))])
         (struct-copy ast-tuple tup
                      [state
                       (~> (dict-map st
                                     (lambda (k v)
                                       (define v-p
                                         (match v
                                           [(blocked dirt cln) dirt]
                                           [_ v]))
                                       `(,k . ,v-p)))
                           state-dict)]
                      [memory mem]))]
      [(act-stmt '()) tup]
      [(act-stmt mods)
       (define mods-p
         (filter-not (lambda (x) (member x mods))
                     (dict-keys (component-submods comp))))
       (ast-step comp tup (deact-stmt mods-p) #:hook callback)]
      [(if-stmt condition tbranch fbranch)
       (if-valued (check-condition condition tup)
                  (ast-step comp tup tbranch #:hook callback)
                  (ast-step comp tup fbranch #:hook callback)
                  tup)]
      [(ifen-stmt condition tbranch fbranch)
       (~> (if (check-condition condition tup) tbranch fbranch)
           (ast-step comp tup _ #:hook callback))]
      [(while-stmt condition body)
       (if-valued (check-condition condition tup)
                  (let* ([bodyres (ast-step comp tup body #:hook callback)]
                         [res (ast-step comp bodyres ast #:hook callback)])
                    res)
                  tup
                  tup)]
      [(mem-print var)
       (display-mem var tup)
       tup]
      [#f (ast-step comp tup (deact-stmt '()) #:hook callback)]
      [_ (error "Malformed ast!" ast)]))
  (debug "close)\n")
  result)

(define (compute comp inputs
                 #:memory [mem (empty-state)]
                 #:hook [callback void]
                 #:toplevel [toplevel #f])
  (define ast (component-control comp))
  (debug "================\n")
  (debug "(start compute for " (component-name comp))
  (define tup (ast-tuple (input-state inputs) '() (blank-state comp) mem))
  (define result
    (if toplevel
        (parameterize ([toplevel-name (component-name comp)])
          (ast-step comp tup ast #:hook callback))
        (ast-step comp tup ast #:hook callback)))

  (debug "compute result: " (ast-tuple-state result))
  (debug "compute memory: " (ast-tuple-memory result))
  (debug "end compute)\n")
  (debug "================\n")
  result)