(require 'peg)

(defmacro peg-defparse (funname rules &optional transform)
  (let ((parser (peg-translate-rules rules)))
    `(defun ,funname ()
                                        ;,(pp parser)
       (let ((result ,parser)
             (transform ,transform))
         (cond
          ((not transform) result)
          ((symbolp transform) (funcall transform result))
          (t (error "Invalid transform %S" transform)))))))


(defun eimap/parse-unquote-string (str)
  (replace-regexp-in-string "\\\\\\(.\\)" "\\1" str))

(peg-add-method normalize literalstr ()
  `(literalstr))

(peg-add-method translate literalstr ()
  `(when (looking-at "{\\([0-9]+\\)}\x0d\x0a")
     (let* ((litlen (string-to-number (match-string 1)))
            (litstart (match-end 0))
            (litend (+ litstart litlen)))
       (when (>= (point-max) litend)
         (goto-char litstart)
         ,(peg-translate-exp '(action (push (point) peg-stack)))
         (goto-char litend)
         ,(peg-translate-exp '(action
                               (push (buffer-substring-no-properties (pop peg-stack)
                                                                     (point)) peg-stack)))))))

(peg-add-method detect-cycles literalstr (path) nil)
(peg-add-method merge-error literalstr (merged)
  "IMAP literal")

(peg-defparse
 eimap/parse
 (

;;; responses

  (response (or continue-req
                response-data
                response-tagged))

  (continue-req  :type 'continue
                 :params (list "+" SP resp-text CRLF))

  (response-tagged :type 'tag
                   :params (list :tag tag SP resp-cond-state CRLF))

  (response-data :type 'data
                 :params
                 (list
                  "*" SP
                  (or resp-cond-data
                      mailbox-data
                      message-data
                      capability-data) CRLF))


;;; response status and code

  (resp-cond-data  :method 'cond-state
                   :params (list resp-cond-state))
  (resp-cond-state :state (or '"OK"
                              '"NO"
                              '"BAD"
                              '"BYE"
                              '"PREAUTH") SP resp-text)
  (resp-text (opt resp-text-code) text)
  (resp-text-code "["
                  :resp-code
                  (or
                   '"ALERT"
                   '"PARSE"
                   '"READ-ONLY"
                   '"READ-WRITE"
                   (and '"BADCHARSET"
                         :charsets (list (opt SP "(" astring
                                              (* SP astring) ")")))
                   (and (if '"CAPABILITY") capability-data)
                   (and '"PERMANENTFLAGS" SP :flags flag-list)
                   (and '"UIDNEXT" SP :uidnext number)
                   (and '"UIDVALIDITY" SP :uidvalidity number)
                   (and '"UNSEEN" SP :unseen number)
                   (and atom (opt :data SP (substring (+ (and (not "]")
                                                              (any)))))))
                  "]" SP)

  (capability-data "CAPABILITY"
                   :capabilities
                   (list 'param
                         (list (+ SP ;; (or (and "AUTH=" (cons 'AUTH
                                  ;; atom)))
                                  atom))))

  (flag-list "(" (list (opt flag (* SP flag))) ")")
  (flag (or ;; '"\\Answered"
         ;; '"\\Flagged"
         ;; '"\\Deleted"
         ;; '"\\Seen"
         ;; '"\\Draft"
         ;; '"\\Recent"
         atom
         flag-extension))
  (flag-extension "\\" atom `(s -- (downcase (concat "\\" s))))


;;; mailbox

  (mailbox-data :method
                (or (and '"FLAGS" SP :flags flag-list)
                    (and '"LIST" SP :mailbox-list mailbox-list)
                    (and '"LSUB" SP :mailbox-list mailbox-list)
                    (and '"SEARCH" :result (list (* SP number)))
                    (and '"STATUS" SP mailbox
                         SP "(" status-att-list ")")
                    (and 'EXISTS :exists number SP "EXISTS")
                    (and 'RECENT :recent number SP "RECENT")))

  (mailbox-list (list
                 "("
                 (opt :flags mbx-list-flags)
                 ")" SP
                 :mboxsep (or (and "\"" (substring QUOTED-CHAR)
                                   `(str -- (eimap/parse-unquote-string))
                                   "\"")
                              =nil)
                 SP mailbox))

  (mailbox :mailbox astring)
  (mbx-list-flags (list mbx-list-flag (* SP mbx-list-flag)))
  (mbx-list-flag (or ;; '"\\Noinferiors"
                  ;; '"\\Noselect"
                  ;; '"\\Marked"
                  ;; '"\\Unmarked"
                  flag-extension))

  (status-att-list status-att-pair (* SP status-att-pair))
  (status-att-pair (or (and "MESSAGES" :messages)
                       (and "RECENT" :recent)
                       (and "UIDNEXT" :uidnext)
                       (and "UIDVALIDITY" :uidvalidity)
                       (and "UNSEEN" :unseen))
                    SP number)


;;; message data
  (message-data :msgid number SP
                :method
                (or '"EXPUNGE"
                    (and '"FETCH" SP msg-att)))
  (msg-att "(" (or msg-att-dynamic
                   msg-att-static)
           (* SP (or msg-att-dynamic
                     msg-att-static))
           ")")
  (msg-att-dynamic (and "FLAGS" SP :flags flag-list))
  (msg-att-static (or (and "ENVELOPE" SP :envelope envelope)
                      (and "INTERNALDATE" SP :internaldate quoted)
                      (and "RFC822" SP :rfc822 nstring)
                      (and "RFC822.HEADER" SP :rfc822.header nstring)
                      (and "RFC822.TEXT" SP :rfc822.text nstring)
                      (and "RFC822.SIZE" SP :rfc822.size number)
                      (and "BODY" SP :body body)
                      (and "BODYSTRUCTURE" SP :bodystructure body)
                      (and "BODY" :bodydata
                           (list section
                                 (opt :offset  "<" number ">") SP
                                 :data nstring))
                      (and "UID" SP :uid number)
                      ))
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

  (envelope "("
            (list
             :date nstring SP
             :subject nstring SP
             :from env-addr-list SP
             :sender env-addr-list SP
             :reply-to env-addr-list SP
             :to env-addr-list SP
             :cc env-addr-list SP
             :bcc env-addr-list SP
             :in-reply-to nstring SP
             :message-id nstring)
            ")")
  (env-addr-list (or (and "(" (list (+ address)) ")")
                     =nil))
  (address "("
           (list
            :name nstring SP
            :adl nstring SP
            :mailbox nstring SP
            :host nstring)
           ")")

;;; body

  (body "(" (list (or body-type-1part
                      body-type-mpart)) ")")
  (body-type-1part (or body-type-text
                                        ;body-type-msg
                                        ;body-type-basic
                       )
                                        ;  (opt SP body-ext-1part)
                   )
  (body-ext-1part "XXX")

  (body-type-mpart "XXX")

  (body-type-text (if "\"TEXT\"" SP)
                  mime-type SP body-fields SP :lines number)

  (body-type-msg "XXX")
  (body-type-basic "XXX")

  (mime-type :mime-type quoted SP quoted
             `(a b -- `(,a . ,b)))
  (body-fields body-fld-param SP
               body-fld-id SP
               body-fld-desc SP
               body-fld-enc SP
               body-fld-octets)
  (body-fld-param :param
                  (or (and "(" string-pair-list ")")
                      =nil))
  (body-fld-id :id nstring)
  (body-fld-desc :desc nstring)
  (body-fld-enc :enc string)
  (body-fld-octets :octets number)



;;; data extraction

  (string-pair-list (list string-pair (* SP string-pair)))
  (string-pair string SP string
               `(a b -- `(,a . ,b)))

  (=nil "NIL" `(-- nil))

  (text :text (substring (+ TEXT-CHAR)))
  (atom (substring (+ ATOM-CHAR)))
  (tag (substring (+ (not "+") ASTRING-CHAR)))
  (astring (or (substring (+ ASTRING-CHAR))
               string))
  (string (or quoted
              (literalstr)))
  (nstring (or string
               =nil))
  (quoted "\"" (substring (* QUOTED-CHAR)) `(str -- (eimap/parse-unquote-string str)) "\"")

  (number (substring (+ [0-9])) `(str -- (string-to-number str)))


;;; literals

  (SP " ")
  (CRLF "\x0d\x0a")
  (resp-specials ["]"])
  (list-wildcards ["%*"])
  (atom-specials (or ["(){ " ?\x7f]
                     (range 0 31)
                     list-wildcards
                     quoted-specials
                     resp-specials))
  (ATOM-CHAR (not atom-specials) (any))
  (ASTRING-CHAR (or ATOM-CHAR
                    resp-specials))
  (TEXT-CHAR (not ["\x0d\x0a"]) (any))
  (quoted-specials ["\\\""])
  (QUOTED-CHAR (or (and (not quoted-specials) TEXT-CHAR)
                   (and "\\" quoted-specials)))
  )
 'reverse)
