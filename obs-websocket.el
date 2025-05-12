;;; obs-websocket.el --- Interact with Open Broadcaster Software through a websocket   -*- lexical-binding: t; -*-

;; Copyright (C) 2021  Sacha Chua

;; Author: Sacha Chua <sacha@sachachua.com>
;; Keywords: recording streaming
;; Version: 0.10
;; Homepage: https://github.com/sachac/obs-websocket-el
;; Package-Requires: ((emacs "26.1") (websocket))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; You will also need to install:
;; OBS: https://obsproject.com/
;; obs-websocket: https://github.com/Palakis/obs-websocket
;; websocket.el: https://github.com/ahyatt/emacs-websocket

;;; Code:

(require 'websocket)
(require 'json)
(defvar obs-websocket-url "ws://localhost:4444" "URL for OBS instance. Use wss:// if secured by TLS.")
(defvar obs-websocket-password nil "Password for OBS.")
(defvar obs-websocket nil "Socket for communicating with OBS.")
(defvar obs-websocket-messages nil "Messages from OBS.")
(defvar obs-websocket-message-id 0 "Starting message ID.")
(defvar obs-websocket-rpc-version 1 "Lastest OBS RPC version supported.")
(defvar obs-websocket-obs-websocket-version nil "Connected OBS' Web Socket Version")
(defvar obs-websocket-obs-studio-version nil "Connected OBS' Studio Version")
(defvar obs-websocket-on-message-payload-functions '(obs-websocket-marshall-message ;obs-websocket-report-status
                                                     )
  "Functions to call when messages arrive.")
(defvar obs-websocket-debug nil "Debug messages")
(defvar obs-websocket-message-callbacks nil "Alist of (message-id . callback-func)")
(defvar obs-websocket-streaming-p nil "Non-nil if streaming.")
(defvar obs-websocket-recording-p nil "Non-nil if recording.")
(defvar obs-websocket-status "" "Modeline string.")
(defvar obs-websocket-scene "" "Current scene.")
(defvar obs-websocket-recording-filename nil "Filename of current or most recent recording.")

(defun obs-websocket-update-mode-line ()
  "Update the text for the mode line."
  (let ((info
         (concat "OBS:"
                 obs-websocket-scene
                 (if (or obs-websocket-streaming-p obs-websocket-recording-p)
                     (concat
                      "*"
                      (if obs-websocket-streaming-p "Str" "")
                      (if obs-websocket-recording-p "Rec" "")
                      "*")
                   ""))))
    (setq obs-websocket-status info)))

(define-minor-mode obs-websocket-minor-mode
  "Minor mode for OBS Websocket."
  :init-value nil
  :lighter " OBS"
  :global t
  (let ((info '(obs-websocket-minor-mode obs-websocket-status " ")))
    (if obs-websocket-minor-mode
        ;; put in modeline
        (add-to-list 'mode-line-front-space info)
      ;; remove from modeline
      (setq mode-line-front-space
            (seq-remove (lambda (x)
                          (and (listp x) (equal (car x) 'obs-websocket-minor-mode)))
                        mode-line-front-space)))))

(defun obs-websocket-report-status (payload)
  "Print friendly messages for PAYLOAD."
  (if (and (equal (plist-get payload :status) "error")
           (not (plist-get payload :authRequired)))
      (error "OBS: %s" (plist-get payload :error))
    (let ((msg
           (pcase (plist-get payload :update-type)
             ("SwitchScenes"
              (setq obs-websocket-scene (plist-get payload :scene-name))
              (format "Switched scene to %s" (plist-get payload :scene-name)))
             ("StreamStarting" "Stream starting.")
             ("StreamStarted"
              (setq obs-websocket-streaming-p t)
              (obs-websocket-update-mode-line)
              "Started streaming.")
             ("StreamStopped"
              (setq obs-websocket-streaming-p nil)
              (obs-websocket-update-mode-line)
              "Stopped streaming.")
             ("RecordingStarted"
              (setq obs-websocket-recording-p t
                    obs-websocket-recording-filename (plist-get payload :recordingFilename))
              (obs-websocket-update-mode-line)
              "Started recording.")
             ("RecordingStopped"
              (setq obs-websocket-recording-p nil)
              (obs-websocket-update-mode-line)
              "Stopped recording")
             ("StreamStatus"
              (setq obs-websocket-streaming-p t)
              ;(prin1 payload)
              nil)
             )))
      (when msg (message "OBS: %s" msg)))))

(cl-defun obs--auth-string (&key salt challenge password &allow-other-keys)
  "Creates an OBS-expected authentication string from"
  (cl-flet ((obs-encode (string-1 string-2)
              (base64-encode-string
               (secure-hash 'sha256 (concat string-1 string-2) nil nil t))))
    (obs-encode (obs-encode password salt)
                challenge)))

(defun obs-websocket-authenticate-if-needed (payload)
  "Authenticate if PAYLOAD asks for it."
  (pcase-let ((`(:authentication ,auth-data) payload))
    (when auth-data
      (let* ((password (or obs-websocket-password
                           (read-passwd "OBS websocket password:")))
             (auth (apply #'obs--auth-string (append auth-data (list :password password)))))
        (when obs-websocket-debug
          (push (list :authenticating auth) obs-websocket-messages))
        (obs-websocket-send-identify auth)))))

(defun obs-websocket-marshall-message (payload)
  (pcase-let ((`( :d ,message-data :op ,opcode ) payload))
    (cl-check-type opcode (integer 0 *) "positive integer op code expected")
    (cl-ecase opcode
      (0 (obs-websocket-authenticate-if-needed message-data))
      (2 (when obs-websocket-debug
           (push (list :identified payload) obs-websocket-messages)))
      (5 (when obs-websocket-debug
           (push (list :event payload) obs-websocket-messages)))
      (7 (when obs-websocket-debug
           (push (list :requestResponse payload) obs-websocket-messages))
         (pcase-let ((`(:requestId ,request-id) message-data))
           (when-let ((callback (assoc request-id obs-websocket-message-callbacks)))
             (catch 'err
               (funcall (cdr callback) message-data))
             (setf obs-websocket-message-callbacks
                   (assoc-delete-all request-id obs-websocket-message-callbacks)))))
      ;; (t (when obs-websocket-debug
      ;;      (push (list :unhandled payload) obs-websocket-messages)))
      )))

(defun obs-websocket-on-message (websocket frame)
  "Handle OBS WEBSOCKET sending FRAME."
  (when obs-websocket-debug
    (setq obs-websocket-messages (cons frame obs-websocket-messages)))
  (let* ((payload (json-parse-string (websocket-frame-payload frame)
                                     :object-type 'plist :array-type 'list)))
    (run-hook-with-args 'obs-websocket-on-message-payload-functions payload)))

(defun obs-websocket-on-close (&rest args)
  "Display a message when the connection has closed."
  (setq obs-websocket nil)
  (message "OBS connection closed."))

(defun obs-websocket-send (request-type &rest args)
  "Send a request of type REQUEST-TYPE."
  (when-let ((callback (plist-get args :callback)))
    (add-to-list 'obs-websocket-message-callbacks
                 (cons (number-to-string obs-websocket-message-id)
                       callback))
    (cl-remf args :callback))
  (let ((msg (json-encode-plist
              (list :op 6
                    :d
                    (append (list :requestType request-type
                                  :requestId (number-to-string obs-websocket-message-id))
                            (when args
                              (list :requestData args)))))))
    (websocket-send-text obs-websocket msg)
    (when obs-websocket-debug (prin1 msg)))
  (setq obs-websocket-message-id (1+ obs-websocket-message-id)))

(defun obs-websocket-send-identify (auth-string)
  (let ((msg (json-encode-plist
              (list :op 1
                    :d (list :rpcVersion obs-websocket-rpc-version
                             :authentication auth-string)))))
    (when obs-websocket-debug
      (push (list :identifying msg) obs-websocket-messages))
    (websocket-send-text obs-websocket msg)))

(defun obs-websocket-disconnect ()
  "Disconnect from an OBS instance."
  (interactive)
  (when obs-websocket (websocket-close obs-websocket)))

(defun obs-websocket-connect (&optional url password)
  "Connect to an OBS instance."
  (interactive (list (or obs-websocket-url (read-string "URL: ")) nil))
  (let ((obs-websocket-password (or password obs-websocket-password)))
    (setq obs-websocket (websocket-open (or url obs-websocket-url)
                                        :on-message #'obs-websocket-on-message
                                        :on-close #'obs-websocket-on-close))

    ;; Poor man's async to wait for identification
    (sleep-for 0.1)

    (obs-websocket-send "GetStreamStatus"
                        :callback (lambda (payload)
                                    (pcase-let ((`(:responseData ,data) payload))
                                      (setq obs-websocket-streaming-p (eq (plist-get data :outputActive) t)))
                                    (obs-websocket-update-mode-line)))
    (obs-websocket-send "GetRecordStatus"
                        :callback (lambda (payload)
                                    (pcase-let ((`(:responseData ,data) payload))
                                      (setq obs-websocket-recording-p (eq (plist-get data :outputActive) t))
                                      (obs-websocket-update-mode-line))))
    (obs-websocket-send "GetCurrentProgramScene"
                        :callback (lambda (payload)
                                    (pcase-let ((`(:responseData ,data) payload))
                                      (setq obs-websocket-scene (plist-get data :sceneName))
                                      (obs-websocket-update-mode-line))))
    (obs-websocket-minor-mode 1)))



(provide 'obs-websocket)
;;; obs-websocket.el ends here
