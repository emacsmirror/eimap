;;; eimap-generate.el ---

;; Copyright (C) 2013  Simon Schubert

;; Author: Simon Schubert <2@0x2c.org>
;; Created: 20130116

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;;; Code:

(require 'peg)
(require 'cl)

(defun eimap-gen-quote-string (str)
  "Quote \" and \\ for IMAP quoted strings."
  (replace-regexp-in-string "[\\\"]" "\\\\\\&" str))

;;; extend the generator with a literalstr builtin
(peg-add-method normalize-generator literalstr ()
  `(literalstr))

(peg-add-method translate-generator literalstr ()
  `(let ((str (peg-pop-current-list)))
     (peg-push-str-on-stack (format "{%d}\x0d\x0a" (string-bytes str)))
     (peg-push-str-on-stack (make-symbol "--literal-marker--"))
     (peg-push-str-on-stack str)))

(peg-add-method detect-cycles literalstr (path) nil)
(peg-add-method merge-error literalstr (merged)
  "IMAP literal")

(defmacro eimap-defgen (funname &rest rules)
  "Build the generator function for eimap."
  (declare (indent 1))
  `(defun ,funname (data)
     (let ((result
            ,(let* ((peg-creating-generator t)
                    (peg-generator-data 'data))
               (peg-translate-rules rules)))
           result-strs)
       (while result
         (let ((front "")
               next)
           (catch 'out
             (while (setq next (pop result))
               (if (stringp next)
                   (setq front (concat front next))
                 (assert (symbolp next))
                 (throw 'out nil))))
           (push front result-strs)))
       (nreverse result-strs))))

(eval-when-compile
  (eimap-defgen eimap-generate
    (command tag SP (or command-any
                        command-auth
                        command-nonauth
                        command-select) CRLF)

    (command-any :method (or '"CAPABILITY"
                             '"LOGOUT"
                             '"NOOP"))
    (command-auth :method (or append create delete
                              examine list lsub
                              rename select status
                              subscribe unsubscribe))
    (command-nonauth :method (or ;; login not supported
                              authenticate
                              ;; no STARTTLS - handled by connection layer
                              ))
    (command-select (opt uid)
                    :method (or '"CHECK"
                                '"CLOSE"
                                '"EXPUNGE"
                                copy
                                fetch
                                store
                                search))

    (append '"APPEND" SP :mailbox mailbox (opt SP :flags flag-list)
            (opt SP :date date-time) SP :data literal)
    (flag-list "(" (list (opt flag (* SP flag))) ")")

    (create '"CREATE" SP :mailbox mailbox)
    (delete '"DELETE" SP :mailbox mailbox)
    (examine '"EXAMINE" SP :mailbox mailbox)
    (list '"LIST" SP :mailbox mailbox SP :pattern list-mailbox)
    (lsub '"LSUB" SP :mailbox mailbox SP :pattern list-mailbox)
    (rename '"RENAME" SP :from-mailbox mailbox SP :to-mailbox mailbox)
    (select '"SELECT" SP :mailbox mailbox)

    (status '"STATUS" SP :mailbox mailbox SP
            :attr (list "(" status-att (* SP status-att) ")"))
    (status-att (or '"MESSAGES"
                    '"RECENT"
                    '"UIDNEXT"
                    '"UIDVALIDITY"
                    '"UNSEEN"))

    (subscribe '"SUBSCRIBE" SP :mailbox mailbox)
    (unsubscribe '"UNSUBSCRIBE" SP :mailbox mailbox)

    (authenticate '"AUTHENTICATE" SP :auth-mech atom
                  ;; RFC 4959:
                  (opt SP :auth-token
                       (or (substring "=") ; allow single pad
                           base64)))

    (copy '"COPY" SP :ids sequence-set SP :mailbox mailbox)
    (fetch '"FETCH" SP :ids sequence-set SP
           :attr (or '"ALL"
                     '"FULL"
                     '"FAST"
                     fetch-att
                     (list "(" fetch-att (* SP fetch-att) ")")))
    (fetch-att (or '"ENVELOPE"
                   '"FLAGS"
                   '"INTERNALDATE"
                   '"RFC822"
                   '"RFC822.HEADER"
                   '"RFC822.SIZE"
                   '"RFC822.TEXT"
                   '"BODY"
                   '"BODYSTRUCTURE"
                   '"UID"
                   (cons (or '"BODY"
                             '"BODY.PEEK")
                         section
                         (opt :partial (cons "<" number "." nz-number ">")))))

    (section "[" (opt :section (list section-spec)) "]")
    (section-spec (or section-msgtext
                      (and :part section-part (opt "." section-text))))
    (section-part number (* "." number))
    (section-msgtext :text
                     (or '"HEADER"
                         (and (or '"HEADER.FIELDS"
                                  '"HEADER.FIELDS.NOT")
                              SP :header-list header-list)
                         '"TEXT"))
    (section-text (or section-msgtext
                      :text '"MIME"))
    (header-list "(" (list astring (* SP astring)) ")")

    (store '"STORE" SP :ids sequence-set SP :flags store-att-flags)
    (store-att-flags (opt (or '"+"
                              '"-")) "FLAGS" SP "(" (opt flag (* SP flag)) ")")
    (flag (or ;; '"\\Answered"
           ;; '"\\Flagged"
           ;; '"\\Deleted"
           ;; '"\\Seen"
           ;; '"\\Draft"
           ;; '"\\Recent"
           atom
           flag-extension))
    (flag-extension (substring "\\" atom))

    (uid :uid 't "UID" SP
         (if :method
             (or 'COPY
                 'FETCH
                 'SEARCH
                 'STORE)))

    (search '"SEARCH" (opt SP "CHARSET" SP :charset astring)
            (opt :return search-return-opts)
            :keys (list (+ SP search-key)))
    (search-return-opts SP "RETURN" SP
                        "(" (or search-return-opt
                                (list search-return-opt
                                      (* SP search-return-opt))) ")")
    (search-return-opt (or '"MIN"
                           '"MAX"
                           '"ALL"
                           '"COUNT"))
    (search-key (or
                 '"ALL"
                 '"ANSWERED"
                 (cons '"BCC" SP astring)
                 (cons '"BEFORE" SP date)
                 (cons '"BODY" SP astring)
                 (cons '"CC" SP astring)
                 '"DELETED"
                 '"FLAGGED"
                 (cons '"FROM" SP astring)
                 (cons '"KEYWORD" atom)
                 '"NEW"
                 '"OLD"
                 (cons '"ON" SP date)
                 '"RECENT"
                 '"SEEN"
                 (cons '"SINCE" SP date)
                 (cons '"SUBJECT" SP astring)
                 (cons '"TEXT" SP astring)
                 (cons '"TO" SP astring)
                 '"DRAFT"
                 (cons '"HEADER" SP (cons astring SP astring))
                 (cons '"LARGER" SP number)
                 (cons '"NOT" SP search-key)
                 (cons '"OR" SP (cons search-key SP search-key))
                 (cons '"SENTBEFORE" SP date)
                 (cons '"SENTON" SP date)
                 (cons '"SENTSINCE" SP date)
                 (cons '"SMALLER" SP number)
                 (cons '"UID" SP sequence-set)
                 (cons 'MESSAGE-ID sequence-set)
                 (and "(" (list search-key) ")")))

    (sequence-set (or seq-number
                      seq-range
                      (list (or seq-number
                                seq-range)
                            (* "," (or seq-number
                                       seq-range)))))
    (seq-range (list :from seq-number ":" :to seq-number))
    (seq-number (or nz-number
                    '"*"))

    (mailbox astring)

;;; data generation

    (=nil 'nil "NIL")

    (text :text (substring (* TEXT-CHAR)))
    (atom (substring (+ ATOM-CHAR)))
    (tag :tag (substring (+ (not "+") ASTRING-CHAR)))
    (astring (or (substring (+ ASTRING-CHAR))
                 string))
    (string (or quoted
                literal))
    (nstring (or string
                 =nil))
    (quoted "\"" `(str -- (eimap-gen-quote-string str)) (substring (* QUOTED-CHAR)) "\"")
    (literal (literalstr))

    (number (if (action (integerp (peg-peek-current-list))))
            `(n -- (number-to-string n)) (substring (+ [0-9])))
    (nz-number (if (action (let ((n (peg-peek-current-list)))
                             (and (integerp n)
                                  (> n 0)))))
               `(n -- (number-to-string n)) (substring [1-9] (* [0-9])))

    (base64 (substring (* 4base64-char) (opt base64-terminal)))
    (base64-terminal (or (and base64-char base64-char "==")
                         (and base64-char base64-char base64-char "=")))
    (4base64-char base64-char base64-char base64-char base64-char)
    (base64-char [a-z A-Z 0-9 "+/"])

    (date quoted)                       ; XXX
    (date-time quoted)                  ; XXX
    (list-mailbox (or (+ list-char)
                      string))

;;; literals, common with parse

    (SP " ")
    (CRLF "\x0d\x0a")
    (resp-specials ["]"])
    (list-wildcards ["%*"])
    (list-char (or ATOM-CHAR
                   list-wildcards
                   resp-specials))
    (atom-specials (or ["(){ " #x7f]
                       (range #x00 #x1f)
                       list-wildcards
                       quoted-specials
                       resp-specials))
    (ATOM-CHAR (not atom-specials) CHAR)
    (ASTRING-CHAR (or ATOM-CHAR
                      resp-specials))
    (TEXT-CHAR (not ["\x0d\x0a"]) CHAR)
    (CHAR (range #x01 #x7f))
    (quoted-specials ["\\\""])
    (QUOTED-CHAR (or (and (not quoted-specials) TEXT-CHAR)
                     (and "\\" quoted-specials)))))

(eval '(progn "
("

(eimap-generate '(:tag "c0" :method AUTHENTICATE :auth-mech "PLAIN" :auth-token "FOo="))
(eimap-generate '(:tag "c1" :method CREATE :mailbox "föo"))
(eimap-generate '(:tag "c2" :method SEARCH :keys (ALL (SEEN) (NOT . DELETED) SEEN)))
(eimap-generate '(:tag "c3" :method FETCH :ids 1 :attr (UID BODYSTRUCTURE)))
(eimap-generate '(:tag "c4" :method FETCH :uid t :ids 1 :attr (UID BODYSTRUCTURE)))
;;; (:method SEARCH :keys (:from "foo" :not (:from "foobar")))
;;; (:method SEARCH :keys ((FROM . "foo") (NOT . (FROM . "foobar"))))

))

(provide 'eimap-generate)
;;; eimap-generate.el ends here
