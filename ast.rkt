#lang racket
(require racket/hash
         graph
         "component.rkt"
         "port.rkt")
(provide (struct-out par-comp)
         (struct-out seq-comp)
         (struct-out deact-stmt)
         (struct-out if-stmt)
         (struct-out ifen-stmt)
         (struct-out while-stmt)
         (struct-out ast-tuple)
         compute)

;; type of statements
(struct par-comp (stmts) #:transparent)
(struct seq-comp (stmts) #:transparent)
(struct deact-stmt (mods) #:transparent)
(struct if-stmt (condition tbranch fbranch) #:transparent)
(struct ifen-stmt (condition tbranch fbranch) #:transparent)
(struct while-stmt (condition body) #:transparent)

;; a hash union that tries to make overlapping keys non-false
;;   if v1 or v2 is #f, choose non-false option
;;   otherwise, if both v1 and v2 have values, choose v2
(define (save-hash-union h1 h2)
  (hash-union h1 h2 #:combine (lambda (v1 v2)
                                (cond
                                  [(not v1) v2]
                                  [(not v2) v1]
                                  [else v2]))))

;; a hash union function that always prefers h2 when keys overlap
(define (clob-hash-union h1 h2)
  (hash-union h1 h2 #:combine (lambda (v1 v2) v2)))

(define (input-hash comp lst)
  (define empty-hash
    (make-immutable-hash
     (map (lambda (x) `(,x . #f))
          (append
           (map car (get-edges (component-graph comp)))
           (map (lambda (p)
                  `(,(port-name p) . inf#))
                (component-outs comp))))))
  (clob-hash-union empty-hash
                   (make-immutable-hash (map (lambda (x) `((,(car x) . inf#) . ,(cdr x))) lst))))

(define (transform comp inputs name)
  (if (findf (lambda (x) (equal? name (port-name x))) (component-ins comp))
      (make-immutable-hash `(((,name . inf#) . ,(hash-ref inputs `(,name . inf#)))))
      (begin
        (let* ([sub (get-submod! comp name)]
               [ins (map port-name (component-ins sub))])  ; XXX: deal with port widths
          ;; (println (~v 'transform name ': inputs '-> ins))
          (make-immutable-hash
           (map (lambda (in)
                  (define neighs
                    (sequence->list (in-neighbors (transpose (component-graph comp)) `(,name . ,in))))
                  (define filt-neighs-vals (filter-map (lambda (x) (hash-ref inputs x)) neighs))
                  (define neighs-vals
                    (if (empty? filt-neighs-vals)
                        (map (lambda (x) (hash-ref inputs x)) neighs)
                        filt-neighs-vals))
                  `((,name . ,in) . ,(car neighs-vals)))
                ins))))))

(define (pln x) (println x) x)

(define (top-order comp)
  (define (distMatrix comp)
    (define copy (graph-copy (convert-graph comp)))
    (for-each (lambda (x)
                (add-directed-edge! copy 'start# x))
              (map port-name (component-ins comp)))
    (let-values ([(distMat _) (bfs copy 'start#)])
      (hash-remove (make-immutable-hash (hash-map distMat (lambda (k v) `(,k . ,(- v 1)))))
                   'start#)))

  (define sorted (sort (hash->list (distMatrix comp))
                       (lambda (x y)
                         (< (cdr x) (cdr y)))))
  (reverse
   (car (foldl (lambda (x acc)
                 (if (= (cdr x) (cdr acc))
                     `(,(cons (cons (car x) (caar acc)) (cdar acc)) . ,(cdr acc))
                     `(,(cons `(,(car x)) (car acc)) . ,(+ 1 (cdr acc)))))
               '(() . -1)
               sorted))))

(define (mint-inactive-hash comp name)
  (make-immutable-hash (map
                        (lambda (x)
                          `((,name . ,(port-name x)) . #f))
                        (append
                         (component-outs (get-submod! comp name))
                         (filter-map
                          (lambda (x) (and (equal? name (port-name x))
                                           (port 'inf# (port-width x))))
                          (component-outs comp))))))

;; creates a hash for the outputs of sub-component [name] in [comp]
;; that has values from [hsh]
(define (mint-remembered-hash comp hsh name)
  (define base (mint-inactive-hash comp name))
  (make-immutable-hash
   (hash-map base (lambda (k v) `(,k . ,(hash-ref hsh k))))))

(struct memory-tup (current sub-mem) #:transparent)
;; given a subcomponent (comp name) a state and memory,
;; run subcomponents proc with state and memory and
;; return updated state and memory
(define (submod-compute comp name state tot-mem)
  ;; state is of the form (((sub . port) . val) ...)
  ;; change to ((port . val) ...)
  (define ins
    (make-immutable-hash
     (hash-map state (lambda (k v) `(,(cdr k) . ,v)))))

  ;; get the current submemory out of mem, creating one if
  ;; it doesn't exist
  (define sub-mem
    (if (hash-has-key? tot-mem name)
        (hash-ref tot-mem name)
        (memory-tup (make-immutable-hash)
                    (make-immutable-hash))))

  ;; add memory to ins
  (define ins-p (hash-set ins 'mem# sub-mem))

  (let* ([proc (component-proc (get-submod! comp name))]
         [res (proc ins-p)]
         [sub-mem-p (if (hash-has-key? res 'mem#)
                        (hash-ref res 'mem#)
                        (memory-tup (make-immutable-hash)
                                    (make-immutable-hash)))]
         ;; [mem (hash-ref res 'mem)]
         [res-wo-mem (hash-remove res 'mem#)])
    (values
     (make-immutable-hash
      (hash-map res-wo-mem
                (lambda (k v) `((,name . ,k) . ,v))))
     (hash-set tot-mem name sub-mem-p))))

(define (compute-step comp memory state inactive)
  ;; sort the components so that we evaluate things in the right order
  ;; (define order (top-order comp))
  (define order (tsort (convert-graph comp)))

  ;; function that goes through a given hashmap and sets all disabled wires to false
  (define (filt hsh)
    (make-immutable-hash
     (hash-map hsh (lambda (k v) (if (member (car k) inactive)
                                     `(,k . #f)
                                     `(,k . ,v))))))
  ;; for every node in the graph, call submod-compute;
  ;; making sure to thread the state through properly
  (struct accum (state memory))
  (define filled
    (foldl (lambda (sub acc)
             (println (~a "<-<" sub "<-<"))
             (define res
               (if (member sub inactive)
                   ; inactive (set sub to false in acc)
                   (struct-copy accum acc
                                [state
                                 ; use save-union because other mods might
                                 ; need values on the wires. we'll set them
                                 ; to #f later
                                 (save-hash-union (accum-state acc)
                                                  (mint-inactive-hash comp sub))])
                   ; active
                   (let*-values
                       (; remove disabled wires from memory, then union with state
                        [(vals) (filt (save-hash-union
                                       (memory-tup-current (accum-memory acc))
                                       (accum-state acc)))]
                        [(trans) (transform comp vals sub)]
                        [(state-p sub-mem-p) ; pass in state and memory to submodule
                         (submod-compute comp sub trans
                                         (memory-tup-sub-mem (accum-memory acc)))]
                        [(curr-mem-p) ; update this modules curr memory
                         (if (component-activation-mode (get-submod! comp sub))
                             ; is a register, update memory
                             ; prefering first non-false then new vals
                             (save-hash-union (memory-tup-current (accum-memory acc))
                                              (mint-remembered-hash comp state-p sub))
                             ; is not a register
                             (memory-tup-current (accum-memory acc)))])
                     (println inactive) (println (memory-tup-current (accum-memory acc)))
                     (println vals) (println trans) (println state-p)
                     (accum
                      (save-hash-union (accum-state acc) state-p)
                      (memory-tup curr-mem-p sub-mem-p))
                     ;; (cons (save-hash-union (car acc) state-p) mem-p)
                     )))
             (println (~a ">->" sub ">->"))
             res)
           (accum state memory)
           order))

  ;; after we have used all the values, set the wires coming from inactive modules to #f
  (define filled-mod
    (foldl (lambda (x acc)
             (hash-set acc x #f))
           (accum-state filled)
           (filter (lambda (x) (member (car x) inactive))
                   (hash-keys (accum-state filled)))))

  ;; (define filled-mod filled)
  (values
   filled-mod                ; state
   (accum-memory filled)     ; memory
   (map (lambda (x)          ; output
          `(,(car x) . ,(hash-ref (accum-state filled) x)))
        (map (lambda (x) `(,(port-name x) . inf#)) (component-outs comp)))))

;; XXX: fix the computation for parallel composition
;; run all computations in "parallel" and then merge the results

(define-syntax-rule (if-valued condition tbranch fbranch)
  (if condition
      (if (not (equal? condition 0))
          tbranch
          fbranch)
      (void)))

(struct ast-tuple (inactive state memory history) #:transparent)

;; a hash union function that chooses non-false values
;; over false ones, keeps equal values the same,
;; and errors on non-equal values
(define (equal-hash-union h0 h1 #:error [error-msg "Invalid merge!"])
  (hash-union h0 h1
              #:combine
              (lambda (v0 v1)
                (cond
                  [(and v0 (not v1)) v0] ; v0 not false, v1 false, then v0
                  [(and (not v0) v1) v1] ; v0 false, fb not false, then v1
                  [(equal? v0 v1) v0]    ; v0 = v1, then v0
                  [else (error error-msg h0 h1)]))))

(define (merge-state st0 st1)
  (equal-hash-union st0 st1))

(define (merge-mem mem0 mem1)
  (let*-values ([(curr0 curr1)
                 (values (memory-tup-current mem0)
                         (memory-tup-current mem1))]
                [(subm0 subm1)
                 (values (memory-tup-sub-mem mem0)
                         (memory-tup-sub-mem mem1))])
    (memory-tup (equal-hash-union curr0 curr1 #:error "Invalid current mem merge!")
                (equal-hash-union subm0 subm1))))

;; XXX fix/justify memory merge
;; type test = (submod -> memory * test)
;; (component * tup * ast) -> (tup')
(define (ast-step comp tup ast)
  ;; (println "-----------------")
  ;; (println ast)
  (define-values (inactive state memory history)
    (match tup
      [(ast-tuple inactive state memory history)
       (values inactive state memory history)]))
  (define result
    (match ast
      [(par-comp stmts)
       (begin
         (println (~a "===- " stmts " -==="))
         (println tup)
         (define res
           (if (empty? stmts)
               ; no stmts, run compute-step
               (let-values ([(st mem out)
                             (compute-step comp
                                           (ast-tuple-memory tup)
                                           (ast-tuple-state tup)
                                           (ast-tuple-inactive tup))])
                 (struct-copy ast-tuple tup
                              [state st]
                              [memory mem]))
               ; there are stmts! fold over them
               (foldl (lambda (s acc)
                        (let*-values ([(acc-p) (ast-step comp tup s)]
                                      [(st mem out)
                                       (compute-step comp
                                                     (ast-tuple-memory acc-p)
                                                     (ast-tuple-state acc-p)
                                                     (ast-tuple-inactive acc-p))])
                          (struct-copy ast-tuple acc
                                       [inactive (remove-duplicates ; XXX why do we merge inactive?
                                                  (append
                                                   (ast-tuple-inactive acc-p)
                                                   (ast-tuple-inactive acc)))]
                                       [state (merge-state st (ast-tuple-state acc))]
                                       [memory mem ;; (merge-mem mem (ast-tuple-memory acc))
                                               ])))
                      ; the accum starts out with no state and no memory
                      ; we never need to merge the starting state/mem with
                      ; the state/mem calcuated in this step. rather, we
                      ; use the starting state/mem to compute the new state/mem
                      ; and then merge those with each other and pass those on
                      (struct-copy ast-tuple tup
                                   [state (make-immutable-hash)]
                                   [memory (memory-tup (make-immutable-hash) (make-immutable-hash))])
                      stmts)))
         (println tup)
         (println res)
         (println (ast-tuple-inactive res))
         (println "===--===")
         res)]
      [(seq-comp stmts)
       (foldl (lambda (s acc)
                (define acc-p (struct-copy ast-tuple acc
                                           [inactive (ast-tuple-inactive tup)]))
                (define res (ast-step comp acc-p s))
                (struct-copy ast-tuple res
                             [history (cons res (ast-tuple-history res))]))
              tup
              stmts)]
      [(deact-stmt mods) (ast-tuple (remove-duplicates
                                     (append mods inactive))
                                    state
                                    memory
                                    history)]
      [(if-stmt condition tbranch fbranch)
       (if-valued (hash-ref state condition)
                  (ast-step comp tup tbranch)
                  (ast-step comp tup fbranch))]
      [(ifen-stmt condition tbranch fbranch)
       (if (hash-ref state condition)
           (ast-step comp tup tbranch)
           (ast-step comp tup fbranch))]
      [(while-stmt condition body)
       (if-valued (hash-ref state condition)
                  (begin
                    (println state)
                    ;; (struct-copy ast-tuple [history (cons state history)])
                    (ast-step comp (ast-step comp tup body) ast))
                  tup
                  ;; (struct-copy ast-tuple tup [history (cons state history)])
                  )]
      [_ (error "Malformed ast!" ast)]))
  ;; (print "-> ") (println result)
  result)

;; (define comp (simp))
;; (define inputs '((a . 10) (b . 4)))
(define (compute comp inputs #:memory [mem (memory-tup
                                            (make-immutable-hash)
                                            (make-immutable-hash))])
  (define ast (component-control comp))
  (define state (input-hash comp inputs))
  (println "================")
  (println (~a "start compute for " (component-name comp)))
  (print "mem ")
  (println mem)
  (define st-mem
    (struct-copy memory-tup mem
                 [current
                  (clob-hash-union
                   (make-immutable-hash
                    (map (lambda (x) `((,(car x) . inf#) . ,(cdr x)))
                         inputs))
                   (memory-tup-current mem))]))
  (print "st-mem ")
  (println st-mem)
  (define result (ast-step comp (ast-tuple '() state st-mem '()) ast))
  (println (~a "end compute for " (component-name comp)))
  (println (ast-tuple-state result))
  (println "================")

  result
  ;; (list (ast-tuple-state result) (ast-tuple-history result))
  )

;; (compute (counter) '((n . 3)))