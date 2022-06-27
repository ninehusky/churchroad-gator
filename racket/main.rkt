#!/usr/bin/racket
#lang racket

(require racket/cmdline
         rosette
         "synthesize.rkt"
         "compile-to-json.rkt"
         json)

(define architecture
  (make-parameter ""
                  (lambda (v)
                    (match v
                      [(or "xilinx-ultrascale-plus") v]
                      [other (error (format "Unsupported architecture ~a." other))]))))
(define out-format
  (make-parameter ""
                  (lambda (v)
                    (match v
                      [(or "verilog") v]
                      [other (error (format "Unsupported output format ~a." other))]))))
(define instructions (make-parameter '() (lambda (instr) instr)))
(define module-names (make-parameter '() (lambda (name) name)))

(command-line
 #:program "lakeroad"
 #:once-each ["--architecture" arch "Hardware architecture to target." (architecture arch)]
 ["--out-format" fmt "Output format. Supported: 'verilog'" (out-format fmt)]
 #:once-any
 #:multi
 [("--instruction")
  instr
  "The instruction to synthesize, written in Rosette bitvector semantics. Use (var <name> <bw>) to indicate a variable. For example, an 8-bit AND is (bvand (var a 8) (var b 8))."
  (instructions (append (instructions) (list instr)))]
 [("--module-name")
  module-name
  "Name given to the module produced. Each --instruction should be paired with a --module-name."
  (module-names (append (module-names) (list module-name)))])

(when (not (equal? (length (instructions)) (length (module-names))))
  (error "There should be one --module-name per --instruction."))

;;; Parse instruction.
;;;
;;; This function will introduce new symbolic constants. Make sure you have good (vc) hygeine when
;;; calling this function (e.g. by wrapping its invocation with (with-vc)).
;;;
;;; expr The instruction to parse, e.g. '(bvadd (var a 8) (var b 8)).
(define (parse-instruction expr)

  (define (helper expr)
    (match expr
      [`(bvand ,a ,b) (bvand (helper a) (helper b))]
      [`(bvadd ,a ,b) (bvadd (helper a) (helper b))]
      [`(bvnot ,a) (bvnot (helper a))]
      [`(var ,id ,bw) (constant id (bitvector bw))]))

  (helper expr))

;;; Synthesize a Lakeroad implementation of the given instruction.
;;;
;;; Returns a Lakeroad expression.
(define (synthesize instruction architecture)
  (match architecture
    ["xilinx-ultrascale-plus" (synthesize-xilinx-ultrascale-plus-impl instruction)]
    [other
     (error (format "Invalid architecture given (value: ~a). Did you specify --architecture?"
                    other))]))

(for ([instruction (instructions)] [module-name (module-names)])
  (define bv-expr (parse-instruction (read (open-input-string instruction))))
  (define lakeroad-expr (synthesize bv-expr (architecture)))

  (define json-source (lakeroad->jsexpr lakeroad-expr #:module-name module-name))

  (match (out-format)
    ["verilog"
     (when (not (getenv "LAKEROAD_DIR"))
       (error "LAKEROAD_DIR must be set to base dir of Lakeroad"))

     (define json-file (make-temporary-file "rkttmp~a.json"))
     (define verilog-file (make-temporary-file "rkttmp~a.v"))
     (display-to-file (jsexpr->string json-source) json-file #:exists 'update)
     (when (not (with-output-to-string
                 (lambda ()
                   (system
                    (format "yosys -p 'read_json ~a; write_verilog ~a'" json-file verilog-file)))))
       (error "Converting JSON to Verilog via Yosys failed."))

     (displayln (file->string verilog-file))])

  ;;; Clean up the VC and un-bind the symbolic terms created for this instruction.
  (clear-vc!)
  (clear-terms! (symbolics bv-expr)))