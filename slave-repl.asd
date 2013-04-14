(in-package :asdf)

(defsystem :slave-repl
  :depends-on
  (#-asdf3 :uiop :fare-utils :bordeaux-threads :lparallel :poiu
           #-(or clozure sbcl) :iolib)
  :components
  ((:file "slave-repl")))
