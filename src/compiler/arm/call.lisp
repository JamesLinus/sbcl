;;;; the VM definition of function call for the ARM

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;;; Interfaces to IR2 conversion:

;;; Return a wired TN describing the N'th full call argument passing
;;; location.
(defun standard-arg-location (n)
  (declare (type unsigned-byte n))
  (if (< n register-arg-count)
      (make-wired-tn *backend-t-primitive-type* register-arg-scn
                     (elt *register-arg-offsets* n))
      (make-wired-tn *backend-t-primitive-type* control-stack-arg-scn n)))


;;; Make a passing location TN for a local call return PC.  If
;;; standard is true, then use the standard (full call) location,
;;; otherwise use any legal location.  Even in the non-standard case,
;;; this may be restricted by a desire to use a subroutine call
;;; instruction.
(defun make-return-pc-passing-location (standard)
  (if standard
      (make-wired-tn *backend-t-primitive-type* register-arg-scn lra-offset)
      (make-restricted-tn *backend-t-primitive-type* register-arg-scn)))

;;; This is similar to MAKE-RETURN-PC-PASSING-LOCATION, but makes a
;;; location to pass OLD-FP in.
;;;
;;; This is wired in both the standard and the local-call conventions,
;;; because we want to be able to assume it's always there. Besides,
;;; the ARM doesn't have enough registers to really make it profitable
;;; to pass it in a register.
(defun make-old-fp-passing-location (standard)
  (declare (ignore standard))
  (make-wired-tn *fixnum-primitive-type* control-stack-sc-number
                 ocfp-save-offset))

;;; Make the TNs used to hold OLD-FP and RETURN-PC within the current
;;; function. We treat these specially so that the debugger can find
;;; them at a known location.
(defun make-old-fp-save-location (env)
  ;; Unlike the other backends, ARM function calling is designed to
  ;; pass OLD-FP within the stack frame rather than in a register.  As
  ;; such, in order for lifetime analysis not to screw up, we need it
  ;; to be a stack TN wired to the save offset, not a normal TN with a
  ;; wired SAVE-TN.
  (physenv-debug-live-tn (make-wired-tn *fixnum-primitive-type*
                                        control-stack-arg-scn
                                        ocfp-save-offset)
                         env))
(defun make-return-pc-save-location (env)
  (specify-save-tn
   (physenv-debug-live-tn (make-normal-tn *backend-t-primitive-type*) env)
   (make-wired-tn *backend-t-primitive-type*
                  control-stack-arg-scn
                  lra-save-offset)))

;;; Make a TN for the standard argument count passing location.  We
;;; only need to make the standard location, since a count is never
;;; passed when we are using non-standard conventions.
(defun make-arg-count-location ()
  (make-wired-tn *fixnum-primitive-type* immediate-arg-scn nargs-offset))


;;; Make a TN to hold the number-stack frame pointer.  This is
;;; allocated once per component, and is component-live.
(defun make-nfp-tn ()
  (component-live-tn
   (make-wired-tn *fixnum-primitive-type* immediate-arg-scn nfp-offset)))

(defun make-stack-pointer-tn ()
  (make-normal-tn *fixnum-primitive-type*))

(defun make-number-stack-pointer-tn ()
  (make-normal-tn *fixnum-primitive-type*))

;;; Return a list of TNs that can be used to represent an unknown-values
;;; continuation within a function.
(defun make-unknown-values-locations ()
  (list (make-stack-pointer-tn)
        (make-normal-tn *fixnum-primitive-type*)))

;;; This function is called by the ENTRY-ANALYZE phase, allowing
;;; VM-dependent initialization of the IR2-COMPONENT structure.  We push
;;; placeholder entries in the Constants to leave room for additional
;;; noise in the code object header.
(defun select-component-format (component)
  (declare (type component component))
  (dotimes (i code-constants-offset)
    (vector-push-extend nil
                        (ir2-component-constants (component-info component))))
  (values))

;;;; Frame hackery:

;;; Used for setting up the Old-FP in local call.
(define-vop (current-fp)
  (:results (val :scs (any-reg)))
  (:generator 1
    (move val fp-tn)))

(define-vop (xep-allocate-frame)
  (:info start-lab copy-more-arg-follows)
  (:vop-var vop)
  (:temporary (:scs (any-reg)) temp)
  (:generator 1
    ;; Make sure the function is aligned, and drop a label pointing to this
    ;; function header.
    (emit-alignment n-lowtag-bits)
    (trace-table-entry trace-table-fun-prologue)
    (emit-label start-lab)
    ;; Allocate function header.
    (inst simple-fun-header-word)
    (dotimes (i (1- simple-fun-code-offset))
      (inst word 0))
    (inst compute-code code-tn lip-tn start-lab temp)
    ;; Build our stack frames.
    (unless copy-more-arg-follows
      (inst add sp-tn fp-tn
            (* n-word-bytes (sb-allocated-size 'control-stack)))
      (let ((nfp-tn (current-nfp-tn vop)))
        (when nfp-tn
          (error "Don't know how to allocate number stack space"))))
    (trace-table-entry trace-table-normal)))

(define-vop (allocate-frame)
  (:results (res :scs (any-reg))
            (nfp :scs (any-reg)))
  (:info callee)
  (:ignore nfp)
  (:generator 2
    (trace-table-entry trace-table-fun-prologue)
    (move res sp-tn)
    (inst add sp-tn sp-tn (* (max 1 (sb-allocated-size 'control-stack))
                             n-word-bytes))
    (when (ir2-physenv-number-stack-p callee)
      (error "Don't know how to allocate number stack space")
      #!+(or)
      (let* ((nbytes (bytes-needed-for-non-descriptor-stack-frame)))
        (when (> nbytes number-stack-displacement)
          (inst stwu nsp-tn nsp-tn (- (bytes-needed-for-non-descriptor-stack-frame)))
          (inst addi nfp nsp-tn number-stack-displacement))))
    (trace-table-entry trace-table-normal)))

;;; Allocate a partial frame for passing stack arguments in a full call.  Nargs
;;; is the number of arguments passed.  If no stack arguments are passed, then
;;; we don't have to do anything.
(define-vop (allocate-full-call-frame)
  (:info nargs)
  (:results (res :scs (any-reg)))
  (:generator 2
    ;; Unlike most other backends, we store the "OCFP" at frame
    ;; allocation time rather than at function-entry time, largely due
    ;; to a lack of usable registers.
    (move res sp-tn)
    (inst add sp-tn sp-tn (* (max 1 nargs) n-word-bytes))
    (storew fp-tn res ocfp-save-offset)))

;;; Emit code needed at the return-point from an unknown-values call
;;; for a fixed number of values.  VALUES is the head of the TN-REF
;;; list for the locations that the values are to be received into.
;;; NVALS is the number of values that are to be received (should
;;; equal the length of Values).
;;;
;;; MOVE-TEMP is a DESCRIPTOR-REG TN used as a temporary.
;;;
;;; This code exploits the fact that in the unknown-values convention,
;;; a single value return returns with all of the condition flags
;;; clear, whereas a return of other than one value returns with the
;;; condition flags set.
;;;
;;; If 0 or 1 values are expected, then we just emit an instruction to
;;; reset the SP (which will only be executed when other than 1 value
;;; is returned.)
;;;
;;; In the general case, we have to do three things:
;;;  -- Default unsupplied register values.  This need only be done when a
;;;     single value is returned, since register values are defaulted by the
;;;     callee in the non-single case.
;;;  -- Default unsupplied stack values.  This needs to be done whenever there
;;;     are stack values.
;;;  -- Reset SP.  This must be done whenever other than 1 value is returned,
;;;     regardless of the number of values desired.

(defun default-unknown-values (vop values nvals move-temp temp lra-label)
  (declare (type (or tn-ref null) values)
           (type unsigned-byte nvals) (type tn move-temp temp))
  (let ((expecting-values-on-stack (> nvals register-arg-count))
        (values-on-stack temp))
    ;; Pick off the single-value case first.
    (sb!assem:without-scheduling ()
      (note-this-location vop (if (<= nvals 1)
                                  :single-value-return
                                  :unknown-return))

      ;; Default register values for single-value return case.
      ;; The callee returns with condition bits CLEAR in the
      ;; single-value case.
      (when values
        (do ((i 1 (1+ i))
             (val (tn-ref-across values) (tn-ref-across val)))
            ((= i (min nvals register-arg-count)))
          (inst mov :ne (tn-ref-tn val) null-tn)))

      ;; If we're not expecting values on the stack, all that
      ;; remains is to clear the stack frame (for the multiple-
      ;; value return case).
      (unless expecting-values-on-stack
        (inst mov :eq sp-tn ocfp-tn))

      ;; If we ARE expecting values on the stack, we need to
      ;; either move them to their result location or to set their
      ;; result location to the default.
      (when expecting-values-on-stack

        ;; For the single-value return case, fake up NARGS and
        ;; OCFP so that we don't screw ourselves with the
        ;; defaulting and stack clearing logic.
        (inst mov :ne ocfp-tn sp-tn)
        (inst mov :ne nargs-tn n-word-bytes)

        ;; Compute the number of stack values (may be negative if
        ;; not all of the register values are populated).
        (inst sub values-on-stack nargs-tn (fixnumize register-arg-count))

        ;; For each expected stack value...
        (do ((i register-arg-count (1+ i))
             (val (do ((i 0 (1+ i))
                       (val values (tn-ref-across val)))
                      ((= i register-arg-count) val))
                  (tn-ref-across val)))
            ((null val))

          ;; ... Load it if there is a stack value available, or
          ;; default it if there isn't.
          (inst subs values-on-stack values-on-stack 4)
          (loadw move-temp ocfp-tn i 0 :ge)
          (store-stack-tn (tn-ref-tn val) move-temp :ge)
          (store-stack-tn (tn-ref-tn val) null-tn :lt))

        ;; Deallocate the callee stack frame.
        (move sp-tn ocfp-tn)))

    ;; And, finally, recompute the correct value for CODE-TN.
    (inst compute-code code-tn lip-tn lra-label temp))
  (values))

;;;; Unknown values receiving:

;;;    Emit code needed at the return point for an unknown-values call for an
;;; arbitrary number of values.
;;;
;;;    We do the single and non-single cases with no shared code: there doesn't
;;; seem to be any potential overlap, and receiving a single value is more
;;; important efficiency-wise.
;;;
;;;    When there is a single value, we just push it on the stack, returning
;;; the old SP and 1.
;;;
;;;    When there is a variable number of values, we move all of the argument
;;; registers onto the stack, and return Args and Nargs.
;;;
;;;    Args and Nargs are TNs wired to the named locations.  We must
;;; explicitly allocate these TNs, since their lifetimes overlap with the
;;; results Start and Count (also, it's nice to be able to target them).
(defun receive-unknown-values (args nargs start count lra-label temp)
  (declare (type tn args nargs start count temp))
  (inst compute-code code-tn lip-tn lra-label temp)
  (inst str :eq (first *register-arg-tns*) (@ sp-tn n-word-bytes :post-index))
  (inst sub :eq start sp-tn 4)
  (inst mov :eq count (fixnumize 1))
  (do ((arg *register-arg-tns* (rest arg))
       (i 0 (1+ i)))
      ((null arg))
    (storew (first arg) args i 0 :ne))
  (move start args :ne)
  (move count nargs :ne)
  (values))


;;; VOP that can be inherited by unknown values receivers.  The main
;;; thing this handles is allocation of the result temporaries.
(define-vop (unknown-values-receiver)
  (:results
   (start :scs (any-reg))
   (count :scs (any-reg)))
  (:temporary (:sc descriptor-reg :offset ocfp-offset
                   :from :eval :to (:result 0))
              values-start)
  (:temporary (:sc any-reg :offset nargs-offset
               :from :eval :to (:result 1))
              nvals)
  (:temporary (:scs (non-descriptor-reg)) temp))

;;; This hook in the codegen pass lets us insert code before fall-thru entry
;;; points, local-call entry points, and tail-call entry points.  The default
;;; does nothing.
(defun emit-block-header (start-label trampoline-label fall-thru-p alignp)
  (declare (ignore fall-thru-p alignp))
  (when trampoline-label
    (emit-label trampoline-label))
  (emit-label start-label))


;;;; XEP hackery:

;;; We don't need to do anything special for regular functions.
;;;
(define-vop (setup-environment)
  (:info label)
  (:ignore label)
  (:generator 0
    ;; Don't bother doing anything.
    ))

;;; Get the lexical environment from its passing location.
(define-vop (setup-closure-environment)
  (:temporary (:sc descriptor-reg :offset lexenv-offset :target closure
               :to (:result 0))
              lexenv)
  (:results (closure :scs (descriptor-reg)))
  (:info label)
  (:ignore label)
  (:generator 6
    ;; Get result.
    (move closure lexenv)))

;;; Copy a more arg from the argument area to the end of the current frame.
;;; Fixed is the number of non-more arguments.
(define-vop (copy-more-arg)
  ;; The environment here-and-now is not properly initialized.  The
  ;; stack frame is not yet fully allocated, and even if it were most
  ;; of the slots have live data in them that PACK does not know
  ;; about, so we cannot afford a register spill.  As far as the boxed
  ;; registers go, the arg-passing registers (R0, R1, and R2) are
  ;; live, LEXENV is live, and LRA is live.  On the unboxed front,
  ;; NARGS is live.  FP has been set up by the caller, SP is
  ;; protecting our stack arguments, but is otherwise not set up.  NFP
  ;; is not yet set up.  CODE and NULL are set up.  SP and NFP must be
  ;; correctly set up by the time we're done, and OCFP and R8 are
  ;; available for use as temporaries.  If we were any more register
  ;; constrained, we'd be spilling registers manually (rather than
  ;; allowing PACK to do it for us).  -- AJB, 2012-Oct-30
  (:vop-var vop)
  ;; Pack COUNT and DEST into the same register, being careful to tell
  ;; PACK that their lifetimes do not overlap (we're lying to PACK, as
  ;; COUNT is live both before and after DEST, but not while DEST is
  ;; live).
  (:temporary (:sc any-reg :offset ocfp-offset :to :eval) count)
  (:temporary (:sc any-reg :offset ocfp-offset :from :eval) dest)
  (:temporary (:sc descriptor-reg :offset r8-offset) temp)
  (:info fixed)
  (:generator 20
    ;; We open up with a LET to obtain a TN for NFP.  We'll call it
    ;; RESULT, to distinguish it from NFP-as-NFP and to roughly
    ;; parallel the PPC implementation.  We can't use a :TEMPORARY
    ;; here because it would conflict with the existing NFP if there
    ;; is a number-stack frame in play, but we only use it prior to
    ;; actually setting up the "real" NFP.
    (let ((result (make-random-tn :kind :normal
                                  :sc (sc-or-lose 'any-reg)
                                  :offset nfp-offset)))
      ;; And we use ASSEMBLE here so that we get "implcit labels"
      ;; rather than having to use GEN-LABEL and EMIT-LABEL.
      (assemble ()
        ;; Compute the end of the fixed stack frame (start of the MORE
        ;; arg area) into RESULT.
        (inst add result fp-tn
              (* n-word-bytes (sb-allocated-size 'control-stack)))
        ;; Compute the end of the MORE arg area (and our overall frame
        ;; allocation) into the stack pointer.
        (cond ((zerop fixed)
               (inst cmp nargs-tn 0)
               (inst add sp-tn result nargs-tn)
               (inst b :eq DONE))
              (t
               (inst subs count nargs-tn (fixnumize fixed))
               (inst b :le DONE)
               (inst add sp-tn result count)))

        (when (< fixed register-arg-count)
          ;; We must stop when we run out of stack args, not when we
          ;; run out of more args.
          (inst add result result (fixnumize (- register-arg-count fixed))))

        ;; Initialize dest to be end of stack.
        (move dest sp-tn)

        ;; We are copying at most (- NARGS FIXED) values, from last to
        ;; first, in order to shift them out of the allocated part of
        ;; the stack frame.  The FIXED values remain where they are,
        ;; as they are part of the allocated stack frame.  Any
        ;; remaining values are being moved to just beyond the end of
        ;; the allocated stack frame, for a distance of (-
        ;; (sb-allocated-size 'control-stack) fixed) words.  There is
        ;; a constant displacement of a single word in the loop below,
        ;; because DEST points to the space AFTER the value being
        ;; moved.

        LOOP
        (inst cmp dest result)
        (let ((delta (- (sb-allocated-size 'control-stack) fixed)))
          (inst ldr :gt temp (@ dest (- (* (1+ delta) n-word-bytes)))))
        (inst str :gt temp (@ dest (- n-word-bytes) :pre-index))
        (inst b :gt LOOP)

        DO-REGS
        (when (< fixed register-arg-count)
          ;; Now we have to deposit any more args that showed up in registers.
          (inst subs count nargs-tn (fixnumize fixed))
          (do ((i fixed (1+ i)))
              ((>= i register-arg-count))
            ;; Don't deposit any more than there are.
            (inst b :eq DONE)
            (inst subs count count (fixnumize 1))
            ;; Store it into the space reserved to it, by displacement
            ;; from the frame pointer.
            (storew (nth i *register-arg-tns*)
                    fp-tn (+ (sb-allocated-size 'control-stack)
                             (- i fixed)))))
        DONE

        ;; Now that we're done with the &MORE args, we can set up the
        ;; number stack frame.
        (let ((nfp-tn (current-nfp-tn vop)))
          (when nfp-tn
            (error "Don't know how to allocate number stack space")))))))

;;; More args are stored consecutively on the stack, starting
;;; immediately at the context pointer.  The context pointer is not
;;; typed, so the lowtag is 0.
(define-full-reffer more-arg * 0 0 (descriptor-reg any-reg) * %more-arg)

;;; Turn more arg (context, count) into a list.
(define-vop (listify-rest-args)
  (:args (context-arg :target context :scs (descriptor-reg))
         (count-arg :target count :scs (any-reg)))
  (:arg-types * tagged-num)
  (:temporary (:scs (any-reg) :from (:argument 0)) context)
  (:temporary (:scs (any-reg) :from (:argument 1)) count)
  (:temporary (:scs (descriptor-reg) :from :eval) temp)
  (:temporary (:scs (any-reg) :from :eval) dst)
  (:temporary (:sc non-descriptor-reg :offset ocfp-offset) pa-flag)
  (:results (result :scs (descriptor-reg)))
  (:translate %listify-rest-args)
  (:policy :safe)
  (:node-var node)
  (:generator 20
    (move context context-arg)
    (move count count-arg)
    ;; Check to see if there are any arguments.
    (inst cmp count 0)
    (move result null-tn)
    (inst b :eq DONE)

    ;; We need to do this atomically.
    (pseudo-atomic (pa-flag)
      ;; Allocate a cons (2 words) for each item.
      (if (node-stack-allocate-p node)
          #!-(or)
          (error "Don't know how to stack-allocate an &REST list.")
          #!+(or)
          (progn
            (align-csp temp)
            (inst clrrwi result csp-tn n-lowtag-bits)
            (inst ori result result list-pointer-lowtag)
            (move dst result)
            (inst slwi temp count 1)
            (inst add csp-tn csp-tn temp))
          (progn
            (inst mov temp (lsl count 1))
            (allocation result temp list-pointer-lowtag
                        :flag-tn pa-flag)
            (move dst result)))

      ;; FIXME: This entire loop is based on the PPC version, which is
      ;; a poor fit for the ARM instruction set.
      (inst b ENTER)

      ;; Compute the next cons and store it in the current one.
      LOOP
      (inst add dst dst (* 2 n-word-bytes))
      (storew dst dst -1 list-pointer-lowtag)

      ;; Grab one value.
      ENTER
      (loadw temp context)
      (inst add context context n-word-bytes)

      ;; Dec count, and if != zero, go back for more.
      (inst subs count count (fixnumize 1))
      ;; Store the value into the car of the current cons (in the delay
      ;; slot).
      (storew temp dst 0 list-pointer-lowtag)
      (inst b :gt LOOP)

      ;; NIL out the last cons.
      (storew null-tn dst 1 list-pointer-lowtag))
    DONE))

;;; Return the location and size of the more arg glob created by
;;; Copy-More-Arg.  Supplied is the total number of arguments supplied
;;; (originally passed in NARGS.)  Fixed is the number of non-rest
;;; arguments.
;;;
;;; We must duplicate some of the work done by Copy-More-Arg, since at
;;; that time the environment is in a pretty brain-damaged state,
;;; preventing this info from being returned as values.  What we do is
;;; compute supplied - fixed, and return a pointer that many words
;;; below the current stack top.
(define-vop (more-arg-context)
  (:policy :fast-safe)
  (:translate sb!c::%more-arg-context)
  (:args (supplied :scs (any-reg)))
  (:arg-types tagged-num (:constant fixnum))
  (:info fixed)
  (:results (context :scs (descriptor-reg))
            (count :scs (any-reg)))
  (:result-types t tagged-num)
  (:note "more-arg-context")
  (:generator 5
    (inst sub count supplied (fixnumize fixed))
    (inst sub context sp-tn count)))

(define-vop (verify-arg-count)
  (:policy :fast-safe)
  (:translate sb!c::%verify-arg-count)
  (:args (nargs :scs (any-reg)))
  (:arg-types positive-fixnum (:constant t))
  (:temporary (:sc non-descriptor-reg :offset ocfp-offset) error-temp)
  (:info count)
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 3
    (let ((err-lab
           (generate-error-code vop error-temp
                                'invalid-arg-count-error nargs)))
      (inst cmp nargs (fixnumize count))
      (inst b :ne err-lab))))

;;; Signal various errors.
(macrolet ((frob (name error translate &rest args)
             `(define-vop (,name)
                ,@(when translate
                    `((:policy :fast-safe)
                      (:translate ,translate)))
                (:args ,@(mapcar #'(lambda (arg)
                                     `(,arg :scs (any-reg descriptor-reg)))
                                 args))
                (:temporary (:sc non-descriptor-reg :offset ocfp-offset) error-temp)
                (:vop-var vop)
                (:save-p :compute-only)
                (:generator 1000
                  (error-call vop error-temp ',error ,@args)))))
  (frob arg-count-error invalid-arg-count-error
    sb!c::%arg-count-error nargs)
  (frob type-check-error object-not-type-error sb!c::%type-check-error
    object type)
  (frob layout-invalid-error layout-invalid-error sb!c::%layout-invalid-error
    object layout)
  (frob odd-key-args-error odd-key-args-error
        sb!c::%odd-key-args-error)
  (frob unknown-key-arg-error unknown-key-arg-error
        sb!c::%unknown-key-arg-error key)
  (frob nil-fun-returned-error nil-fun-returned-error nil fun))

;;;; Local call with known values return:

;;; Non-TR local call with known return locations.  Known-value return works
;;; just like argument passing in local call.
;;;
;;; Note: we can't use normal load-tn allocation for the fixed args, since all
;;; registers may be tied up by the more operand.  Instead, we use
;;; MAYBE-LOAD-STACK-TN.
(define-vop (known-call-local)
  (:args (fp)
         (nfp)
         (args :more t))
  (:results (res :more t))
  (:move-args :local-call)
  (:save-p t)
  (:info save callee target)
  (:ignore args res save)
  (:vop-var vop)
  (:temporary (:sc control-stack :offset nfp-save-offset) nfp-save)
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:temporary (:scs (interior-reg)) lip)
  (:generator 5
    (trace-table-entry trace-table-call-site)
    (let ((label (gen-label))
          (cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (store-stack-tn nfp-save cur-nfp))
      (let ((callee-nfp (callee-nfp-tn callee)))
        (when callee-nfp
          (maybe-load-stack-tn callee-nfp nfp)))
      (maybe-load-stack-tn fp-tn fp)
      (inst compute-lra (callee-return-pc-tn callee) lip label)
      (note-this-location vop :call-site)
      (inst b target)
      (emit-return-pc label)
      (note-this-location vop :known-return)
      (when cur-nfp
        (load-stack-tn cur-nfp nfp-save)))
    (trace-table-entry trace-table-normal)))

;;; Return from known values call.  We receive the return locations as
;;; arguments to terminate their lifetimes in the returning function.  We
;;; restore FP and CSP and jump to the Return-PC.
;;;
;;; Note: we can't use normal load-tn allocation for the fixed args, since all
;;; registers may be tied up by the more operand.  Instead, we use
;;; MAYBE-LOAD-STACK-TN.
(define-vop (known-return)
  (:args (old-fp :target old-fp-temp)
         (return-pc :target return-pc-temp)
         (vals :more t))
  (:temporary (:sc any-reg :from (:argument 0)) old-fp-temp)
  (:temporary (:sc descriptor-reg :from (:argument 1)) return-pc-temp)
  (:move-args :known-return)
  (:info val-locs)
  (:ignore val-locs vals)
  (:vop-var vop)
  (:generator 6
    (trace-table-entry trace-table-fun-epilogue)
    (maybe-load-stack-tn old-fp-temp old-fp)
    (maybe-load-stack-tn return-pc-temp return-pc)
    (move sp-tn fp-tn)
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (error "Don't know how to release number stack allocation")
        #!+(or)
        (inst addi nsp-tn cur-nfp
              (- (bytes-needed-for-non-descriptor-stack-frame)
                 number-stack-displacement))))
    (move fp-tn old-fp-temp)
    ;; Shouldn't use LISP-RETURN here because we don't need to signal
    ;; single / multiple values.
    (inst sub pc-tn return-pc-temp (- other-pointer-lowtag 4))
    (trace-table-entry trace-table-normal)))

;;;; Full call:
;;;
;;; There is something of a cross-product effect with full calls.
;;; Different versions are used depending on whether we know the
;;; number of arguments or the name of the called function, and
;;; whether we want fixed values, unknown values, or a tail call.
;;;
;;; In full call, the arguments are passed creating a partial frame on
;;; the stack top and storing stack arguments into that frame.  On
;;; entry to the callee, this partial frame is pointed to by FP.  If
;;; there are no stack arguments, we don't bother allocating a partial
;;; frame, and instead set FP to SP just before the call.

;;; This macro helps in the definition of full call VOPs by avoiding code
;;; replication in defining the cross-product VOPs.
;;;
;;; Name is the name of the VOP to define.
;;;
;;; Named is true if the first argument is a symbol whose global function
;;; definition is to be called.
;;;
;;; Return is either :Fixed, :Unknown or :Tail:
;;; -- If :Fixed, then the call is for a fixed number of values, returned in
;;;    the standard passing locations (passed as result operands).
;;; -- If :Unknown, then the result values are pushed on the stack, and the
;;;    result values are specified by the Start and Count as in the
;;;    unknown-values continuation representation.
;;; -- If :Tail, then do a tail-recursive call.  No values are returned.
;;;    The Old-Fp and Return-PC are passed as the second and third arguments.
;;;
;;; In non-tail calls, the pointer to the stack arguments is passed as the last
;;; fixed argument.  If Variable is false, then the passing locations are
;;; passed as a more arg.  Variable is true if there are a variable number of
;;; arguments passed on the stack.  Variable cannot be specified with :Tail
;;; return.  TR variable argument call is implemented separately.
;;;
;;; In tail call with fixed arguments, the passing locations are passed as a
;;; more arg, but there is no new-FP, since the arguments have been set up in
;;; the current frame.
(defmacro define-full-call (name named return variable)
  (aver (not (and variable (eq return :tail))))
  `(define-vop (,name
                ,@(when (eq return :unknown)
                    '(unknown-values-receiver)))
     (:args
      ,@(unless (eq return :tail)
          '((new-fp :scs (any-reg) :to :eval)))

      ,(if named
           '(name :target name-pass)
           '(arg-fun :target lexenv))

      ,@(when (eq return :tail)
          '((old-fp)
            (return-pc :target return-pc-pass)))

      ,@(unless variable '((args :more t :scs (descriptor-reg)))))

     ,@(when (eq return :fixed)
         '((:results (values :more t))))

     (:save-p ,(if (eq return :tail) :compute-only t))

     ,@(unless (or (eq return :tail) variable)
         '((:move-args :full-call)))

     (:vop-var vop)
     (:info ,@(unless (or variable (eq return :tail)) '(arg-locs))
            ,@(unless variable '(nargs))
            ,@(when (eq return :fixed) '(nvals))
            step-instrumenting)

     (:ignore
      ,@(unless (or variable (eq return :tail)) '(arg-locs))
      ,@(unless variable '(args))
      ,@(when (eq return :tail) '(old-fp)))

     (:temporary (:sc descriptor-reg
                  :offset lra-offset
                  :from (:argument 1)
                  :to :eval)
                 return-pc-pass)

     (:temporary (:sc descriptor-reg :offset lexenv-offset
                      :from (:argument ,(if (eq return :tail) 0 1))
                      :to :eval)
                 ,(if named 'name-pass 'lexenv))

     (:temporary (:scs (descriptor-reg) :from (:argument 0) :to :eval)
                 function)
     (:temporary (:sc any-reg :offset nargs-offset :to :eval)
                 nargs-pass)

     ,@(when variable
         (mapcar #'(lambda (name offset)
                     `(:temporary (:sc descriptor-reg
                                   :offset ,offset
                                   :to :eval)
                         ,name))
                 *register-arg-names* *register-arg-offsets*))
     ,@(when (eq return :fixed)
         '((:temporary (:scs (descriptor-reg) :from :eval) move-temp)))

     ,@(unless (eq return :tail)
         '((:temporary (:scs (non-descriptor-reg)) temp)
           (:temporary (:scs (interior-reg)) lip)
           (:temporary (:sc control-stack :offset nfp-save-offset) nfp-save)))

     (:generator ,(+ (if named 5 0)
                     (if variable 19 1)
                     (if (eq return :tail) 0 10)
                     15
                     (if (eq return :unknown) 25 0))
       (trace-table-entry trace-table-call-site)
       (let* ((cur-nfp (current-nfp-tn vop))
              ,@(unless (eq return :tail)
                  '((lra-label (gen-label))))
              (step-done-label (gen-label))
              (filler
               (remove nil
                       (list :load-nargs
                             ,@(if (eq return :tail)
                                   '((unless (location= return-pc
                                                        return-pc-pass)
                                       :load-return-pc)
                                     (when cur-nfp
                                       :frob-nfp))
                                   '(:comp-lra
                                     (when cur-nfp
                                       :frob-nfp)
                                     :load-fp))))))
         (flet ((do-next-filler ()
                  (let* ((next (pop filler))
                         (what (if (consp next) (car next) next)))
                    (ecase what
                      (:load-nargs
                       ,@(if variable
                             `((inst sub nargs-pass sp-tn new-fp)
                               ,@(let ((index -1))
                                   (mapcar #'(lambda (name)
                                               `(loadw ,name new-fp
                                                       ,(incf index)))
                                           *register-arg-names*)))
                             '((inst mov nargs-pass (fixnumize nargs)))))
                      ,@(if (eq return :tail)
                            '((:load-return-pc
                               (sc-case return-pc
                                 (descriptor-reg
                                  (inst mov return-pc-pass return-pc))
                                 (control-stack
                                  (loadw return-pc-pass fp-tn
                                         (tn-offset return-pc)))))
                              (:frob-nfp
                               (error "Don't know how to :FROB-NFP for TAIL call")))
                            `((:comp-lra
                               (inst compute-lra return-pc-pass lip lra-label))
                              (:frob-nfp
                               (store-stack-tn nfp-save cur-nfp))
                              (:load-fp
                               (move fp-tn new-fp))))
                      ((nil)))))
                (insert-step-instrumenting (callable-tn)
                  ;; Conditionally insert a conditional trap:
                  (when step-instrumenting
                    ;; Get the symbol-value of SB!IMPL::*STEPPING*
                    #+(or) ;; Doesn't work for :TAIL case.
                    (load-symbol-value temp sb!impl::*stepping*)
                    (error "Don't know how to STEP-INSTRUMENT a CALL"))))


           ,@(if named
                 `((sc-case name
                     (descriptor-reg (move name-pass name))
                     (control-stack
                      (loadw name-pass fp-tn (tn-offset name))
                      (do-next-filler))
                     (constant
                      (loadw name-pass code-tn (tn-offset name)
                             other-pointer-lowtag)
                      (do-next-filler)))
                   (insert-step-instrumenting name-pass)
                   (loadw function name-pass fdefn-raw-addr-slot
                          other-pointer-lowtag)
                   (do-next-filler))
                 `((sc-case arg-fun
                     (descriptor-reg (move lexenv arg-fun))
                     (control-stack
                      (loadw lexenv fp-tn (tn-offset arg-fun))
                      (do-next-filler))
                     (constant
                      (loadw lexenv code-tn (tn-offset arg-fun)
                             other-pointer-lowtag)
                      (do-next-filler)))
                   (loadw function lexenv closure-fun-slot
                          fun-pointer-lowtag)
                   (do-next-filler)
                   (insert-step-instrumenting function)))
           (loop
             (if filler
                 (do-next-filler)
                 (return)))

           (note-this-location vop :call-site)
           (lisp-jump function))

         ,@(ecase return
             (:fixed
              '((emit-return-pc lra-label)
                (default-unknown-values vop values nvals move-temp
                                        temp lra-label)
                (when cur-nfp
                  (load-stack-tn cur-nfp nfp-save))))
             (:unknown
              '((emit-return-pc lra-label)
                (note-this-location vop :unknown-return)
                (receive-unknown-values values-start nvals start count
                                        lra-label temp)
                (when cur-nfp
                  (load-stack-tn cur-nfp nfp-save))))
             (:tail)))
       (trace-table-entry trace-table-normal))))


(define-full-call call nil :fixed nil)
(define-full-call call-named t :fixed nil)
(define-full-call multiple-call nil :unknown nil)
(define-full-call multiple-call-named t :unknown nil)
(define-full-call tail-call nil :tail nil)
(define-full-call tail-call-named t :tail nil)

;;;; Unknown values return:

;;; Return a single value using the unknown-values convention.
(define-vop (return-single)
  (:args (old-fp :scs (any-reg) :to :eval)
         (return-pc :scs (descriptor-reg))
         (value))
  (:ignore value)
  (:vop-var vop)
  (:generator 6
    (trace-table-entry trace-table-fun-epilogue)
    ;; Clear the number stack.
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (error "Don't know how to clear number stack space in RETURN-SINGLE")))
    ;; Clear the control stack, and restore the frame pointer.
    (move sp-tn fp-tn)
    (move fp-tn old-fp)
    ;; Out of here.
    (lisp-return return-pc t)
    (trace-table-entry trace-table-normal)))

;;; Do unknown-values return of a fixed number of values.  The Values are
;;; required to be set up in the standard passing locations.  Nvals is the
;;; number of values returned.
;;;
;;; If returning a single value, then deallocate the current frame, restore
;;; FP and jump to the single-value entry at Return-PC + 8.
;;;
;;; If returning other than one value, then load the number of values returned,
;;; NIL out unsupplied values registers, restore FP and return at Return-PC.
;;; When there are stack values, we must initialize the argument pointer to
;;; point to the beginning of the values block (which is the beginning of the
;;; current frame.)
(define-vop (return)
  (:args
   (old-fp :scs (any-reg))
   (return-pc :scs (descriptor-reg) :to (:eval 1) :target lra)
   (values :more t))
  (:ignore values)
  (:info nvals)
  (:temporary (:sc descriptor-reg :offset r0-offset :from (:eval 0)) r0)
  (:temporary (:sc descriptor-reg :offset r1-offset :from (:eval 0)) r1)
  (:temporary (:sc descriptor-reg :offset r2-offset :from (:eval 0)) r2)
  (:temporary (:sc descriptor-reg :offset lra-offset :from (:eval 1)) lra)
  (:temporary (:sc any-reg :offset nargs-offset) nargs)
  (:temporary (:sc any-reg :offset ocfp-offset) val-ptr)
  (:vop-var vop)
  (:generator 6
    (trace-table-entry trace-table-fun-epilogue)
    (move lra return-pc)
    ;; Clear the number stack.
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (error "Don't know how to clear number stack in VOP RETURN")))
    (cond ((= nvals 1)
           ;; Clear the control stack, and restore the frame pointer.
           (move sp-tn fp-tn)
           (move fp-tn old-fp)
           ;; Out of here.
           (lisp-return lra t))
          (t
           ;; Establish the values pointer and values count.
           (move val-ptr fp-tn)
           (inst mov nargs (fixnumize nvals))
           ;; restore the frame pointer and clear as much of the control
           ;; stack as possible.
           (move fp-tn old-fp)
           (inst add sp-tn val-ptr (* nvals n-word-bytes))
           ;; pre-default any argument register that need it.
           (when (< nvals register-arg-count)
             (dolist (reg (subseq (list r0 r1 r2) nvals))
               (move reg null-tn)))
           ;; And away we go.
           (lisp-return lra nil)))
    (trace-table-entry trace-table-normal)))

;;; Do unknown-values return of an arbitrary number of values (passed
;;; on the stack.)  We check for the common case of a single return
;;; value, and do that inline using the normal single value return
;;; convention.  Otherwise, we branch off to code that calls an
;;; assembly-routine.
(define-vop (return-multiple)
  (:args
   (old-fp-arg :scs (any-reg) :to (:eval 1))
   (lra-arg :scs (descriptor-reg) :to (:eval 1))
   (vals-arg :scs (any-reg) :target vals)
   (nvals-arg :scs (any-reg) :target nvals))
  (:temporary (:sc any-reg :offset lexenv-offset :from (:argument 0)) old-fp)
  (:temporary (:sc descriptor-reg :offset lra-offset :from (:argument 1)) lra)
  (:temporary (:sc any-reg :offset ocfp-offset :from (:argument 2)) vals)
  (:temporary (:sc any-reg :offset nargs-offset :from (:argument 3)) nvals)
  (:temporary (:sc descriptor-reg :offset r0-offset) r0)
  (:vop-var vop)
  (:generator 13
    (trace-table-entry trace-table-fun-epilogue)
    (move lra lra-arg)
    ;; Clear the number stack.
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (error "Don't know how to clear number stack.")
        #!+(or)
        (inst addi nsp-tn cur-nfp
              (- (bytes-needed-for-non-descriptor-stack-frame)
                 number-stack-displacement))))

    ;; Check for the single case.
    (inst cmp nvals-arg (fixnumize 1))
    (inst b :ne NOT-SINGLE)

    ;; Return with one value.
    (inst ldr r0 (@ vals-arg))
    (move sp-tn fp-tn)
    (move fp-tn old-fp-arg)
    (lisp-return lra-arg t)

    ;; Nope, not the single case.
    NOT-SINGLE
    (move old-fp old-fp-arg)
    (move vals vals-arg)
    (move nvals nvals-arg)
    (inst ldr pc-tn (@ fixup))
    FIXUP
    (inst word (make-fixup 'return-multiple :assembly-routine))

    (trace-table-entry trace-table-normal)))