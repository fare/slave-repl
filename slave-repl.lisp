#|
(cl:in-package :cl-user)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :asdf))
(eval-when (:compile-toplevel :load-toplevel :execute)
  (handler-bind ((warning #'muffle-warning))
    (map () 'asdf:require-system
         '(#-asdf3 :uiop :fare-utils :bordeaux-threads :lparallel :poiu
           #-(or clozure sbcl) :iolib))))
|#

(defpackage :slave-repl
  (:use :uiop :fare-utils :cl)
  (:import-from :lparallel.queue
    #:queue #:cons-queue #:make-queue #:push-queue #:pop-queue))

(in-package :slave-repl)

;;; Pipes

#-(or clozure sbcl)
(progn ;; Use IOLib for pipes
  (defun pipe ()
    (iolib-syscalls:pipe))
  (defun make-fd-stream (fd)
    (make-instance 'iolib/streams:dual-channel-gray-stream :fd fd))
  (defun fd-input-stream (fd)
    (make-fd-stream fd))
  (defun fd-output-stream (fd)
    (make-fd-stream fd)))
#+clozure
(progn
  (defun pipe ()
    (ccl::pipe))
  (defun fd-output-stream (fd)
    (ccl::make-fd-stream fd :direction :output))
  (defun fd-input-stream (fd)
    (ccl::make-fd-stream fd :direction :input)))
#+sbcl
(progn
  (defun pipe ()
    (sb-posix:pipe))
  (defun fd-output-stream (fd)
    (sb-sys:make-fd-stream fd :output t))
  (defun fd-input-stream (fd)
    (sb-sys:make-fd-stream fd :input t)))

(defun pipe-streams ()
  (multiple-value-bind (read-fd write-fd) (pipe)
    (values
     (fd-input-stream read-fd)
     (fd-output-stream write-fd))))


;;; Slave thread

(defclass slave-process ()
  ((process
    :initarg :process :reader slave-process)
   (name
    :initarg :name :reader slave-name)
   (to-slave
    :initarg :to-slave :reader to-slave)
   (from-slave
    :initarg :from-slave :reader from-slave)))

(defgeneric send (channel object &key))
(defgeneric recv (channel &key))


;;; Slaving away

(defvar *eof* '#:eof)

(defun run-slave-repl (input &optional output)
  (catch *eof* (loop (slave-toil input output))))

(defun call-with-results (thunk)
  (handler-case (funcall thunk)
    (error (c) (list 'error c))
    (:no-error (&rest values) (list* 'values values))))

(defmacro with-results (() &body body)
  `(call-with-results #'(lambda () ,@body)))

(defun slave-toil (&optional (input *standard-input*) (output *standard-output*))
  (let ((x (recv input :tag :slave-input)))
    (when (eq x *eof*) (throw *eof* nil))
    (let ((results (with-results () (eval x))))
      (when output
        (send output results :tag :slave-output)))))

(defgeneric drive-slave (slave command &key))

(defmethod drive-slave ((slave slave-process) command &key verbose wait)
  (send (to-slave slave)
        (if verbose `(verbosely-eval ',command ',(slave-name slave)) command)
        :tag :to-slave)
  (when wait (slave-results slave)))

(defun slave-results (slave &key &allow-other-keys)
  (let ((results (recv (from-slave slave) :tag :from-slave)))
    (check-type (car results) (member error values))
    (apply 'funcall results)))

(defun verbosely-eval (command &optional name)
  (format! *trace-output* "~&~@[~A: ~]Evaluating ~W~%" name command)
  (let ((results (with-results () (eval command))))
    (format! *trace-output* "~&~@[~A: ~]Returned~{ ~W~}~%" name results)
    (apply 'funcall results)))


;;; Trivial communication through streams

(defun call-with-slave-io-syntax (thunk &key tag)
  (declare (ignore tag))
  (with-safe-io-syntax (:package :cl)
    (let ((*print-escape* t)
          (*print-readably* t)
          (*print-pretty* nil)
          (*read-eval* t))
      (funcall thunk))))

(defmacro with-slave-io-syntax ((&key tag) &body body)
  `(call-with-slave-io-syntax #'(lambda () ,@body) :tag ,tag))

(defmethod send ((channel stream) object &key tag)
  (with-slave-io-syntax (:tag tag)
    (format! channel "~&~W~%" object)))

(defmethod recv ((channel stream) &key tag)
  (with-slave-io-syntax (:tag tag)
    (read-preserving-whitespace channel nil *eof*)))

(defclass slave-fork (slave-process) ())

(defun make-slave-fork (&key (name "slave fork") initial-bindings (class 'slave-fork) initargs)
  (unless (asdf::can-fork-p)
    (error "Can't fork"))
  (multiple-value-bind (from-master to-slave) (pipe-streams)
    (multiple-value-bind (from-slave to-master) (pipe-streams)
      (let ((pid (asdf::posix-fork)))
        (cond
          ((zerop pid)
           (close to-slave)
           (close from-slave)
           (setf *lisp-interaction* nil
                 *fatal-conditions* '(error))
           (with-fatal-condition-handler ()
             (progv
                 (mapcar 'car initial-bindings)
                 (mapcar 'cdr initial-bindings)
               (run-slave-repl from-master to-master)))
           (quit 0))
          (t
           (close from-master)
           (close to-master)
           (apply 'make-instance class
                  :process pid
                  :name (princ-to-string name)
                  :to-slave to-slave :from-slave from-slave
                  initargs)))))))

(defun make-slave-thread (&key (name "slave thread") initial-bindings (class 'slave-process) initargs
                            from-master to-slave from-slave to-master)
  (apply 'make-instance class
         :process (bt:make-thread (lambda () (run-slave-repl from-master to-master))
                                  :name (princ-to-string name) :initial-bindings initial-bindings)
         :name name
         :to-slave to-slave :from-slave from-slave initargs))

(defun make-slave-thread/stream (&rest keys &key (name "slave thread") initial-bindings (class 'slave-process) initargs)
  (declare (ignore name initial-bindings class initargs))
  (multiple-value-bind (from-master to-slave) (pipe-streams)
    (multiple-value-bind (from-slave to-master) (pipe-streams)
      (apply 'make-slave-thread :from-master from-master :to-slave to-slave
             :from-slave from-slave :to-master to-master keys))))

(defgeneric finalize (object))

(defmethod finalize ((slave slave-fork))
  (asdf::posix-wait))

(defmethod send ((channel cons-queue) object &key tag)
  (declare (ignore tag))
  (push-queue object channel))

(defmethod recv ((channel cons-queue) &key tag)
  (declare (ignore tag))
  (pop-queue channel))

(defun make-slave-thread/queue (&rest keys &key (name "slave thread") initial-bindings (class 'slave-process) initargs)
  (declare (ignore name initial-bindings class initargs))
  (let ((to-slave (make-queue))
        (to-master (make-queue)))
    (apply 'make-slave-thread :from-master to-slave :to-slave to-slave
                              :from-slave to-master :to-master to-master keys)))
