(defsystem "slave-repl"
  :version "1.0.0"
  :description "Run code in a REPL in a slave process"
  :author "Francois-Rene Rideau"
  :license "MIT"
  :depends-on ("fare-utils" "bordeaux-threads" "lparallel" "poiu"
                            #-(or clozure sbcl) "iolib")
  :components ((:file "slave-repl")))
