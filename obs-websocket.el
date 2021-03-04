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
(defvar obs-websocket-on-message-payload-functions '(obs-websocket-authenticate-if-needed obs-websocket-report-status)
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

(defun obs-websocket-authenticate-if-needed (payload)
  "Authenticate if PAYLOAD asks for it."
  (when (plist-get payload :authRequired)
    (let* ((challenge (plist-get payload :challenge))
           (salt (plist-get payload :salt))
           (auth (base64-encode-string
                  (secure-hash 'sha256
                               (concat
                                (base64-encode-string
                                 (secure-hash 'sha256
                                              (concat (or obs-websocket-password (read-passwd "OBS password: "))
                                                      salt)
                                              nil nil t))
                                challenge)
                               nil nil t))))
      (obs-websocket-send "Authenticate" :auth auth))))

(defun obs-websocket-on-message (websocket frame)
  "Handle OBS WEBSOCKET sending FRAME."
  (let* ((payload (json-parse-string (websocket-frame-payload frame) :object-type 'plist :array-type 'list))
         (message-id (plist-get payload :message-id))
         (callback (assoc message-id obs-websocket-message-callbacks)))
    (when obs-websocket-debug
      (setq obs-websocket-messages (cons frame obs-websocket-messages)))
    (when callback
      (catch 'err
        (funcall (cdr callback) frame payload))
      (delete callback obs-websocket-message-callbacks))
    (run-hook-with-args 'obs-websocket-on-message-payload-functions payload)))

(defun obs-websocket-on-close (&rest args)
  "Display a message when the connection has closed."
  (setq obs-websocket nil)
  (message "OBS connection closed."))

(defun obs-websocket-send (request-type &rest args)
  "Send a message of type REQUEST-TYPE."
  (when (plist-get args :callback)
    (add-to-list 'obs-websocket-message-callbacks
                  (cons (number-to-string obs-websocket-message-id) (plist-get args :callback)))
    (cl-remf args :callback))
  (let ((msg (json-encode-plist (append
                                 (list :request-type request-type
                                       :message-id (number-to-string obs-websocket-message-id))
                                 
                                 args))))
    (websocket-send-text obs-websocket msg)
    (when obs-websocket-debug (prin1 msg)))
  (setq obs-websocket-message-id (1+ obs-websocket-message-id)))

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
    (obs-websocket-send "GetAuthRequired")
    (obs-websocket-send "GetStreamingStatus"
                        :callback (lambda (frame payload)
                                    (setq obs-websocket-streaming-p (eq (plist-get payload :streaming) t))
                                    (setq obs-websocket-recording-p (eq (plist-get payload :recording) t))
                                    (obs-websocket-update-mode-line)))
    (obs-websocket-send "GetCurrentScene"
                        :callback (lambda (frame payload)
                                    (setq obs-websocket-scene (plist-get payload :name))
                                    (obs-websocket-update-mode-line)))
    (obs-websocket-minor-mode 1)))

(provide 'obs-websocket)
;;; obs-websocket.el ends here
