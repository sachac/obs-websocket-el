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

(defun obs-websocket-report-status (payload)
  (if (equal (plist-get payload :status) "error")
      (error "OBS: %s" (plist-get payload :error))
    (let ((msg
           (pcase (plist-get payload :update-type)
             ("SwitchScenes" (format "Switched scene to %s" (plist-get payload :scene-name)))
             ("StreamStarting" "Stream starting.")
             ("StreamStarted" "Stream started successfully.")
             ("StreamStopped" "Stream stopped.")
             ("RecordingStarting" "Recording starting.")
             ("RecordingStopped" "Recording stopped")
             ("StreamStatus" nil)
             (_ (plist-get payload :update-type)))))
      (when msg (message "OBS: %s" msg)))))

(defun obs-websocket-authenticate-if-needed (payload)
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
  (setq obs-websocket nil)
  (message "OBS connection closed."))

(defun obs-websocket-send (request-type &rest args)
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

(defun obs-websocket-connect (&optional url password)
  "Connect to an OBS instance."
  (interactive (list (read-string "URL: " obs-websocket-url) nil))
  (let ((obs-websocket-password (or password obs-websocket-password)))
    (setq obs-websocket (websocket-open (or url obs-websocket-url)
                                        :on-message #'obs-websocket-on-message
                                        :on-close #'obs-websocket-on-close))
    (obs-websocket-send "GetAuthRequired")))

(provide 'obs-websocket)
