;;; ptemplate.el --- Project templates -*- lexical-binding: t -*-

;; Copyright (C) 2020  Nikita Bloshchanevich

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

;; Author: Nikita Bloshchanevich <nikblos@outlook.com>
;; URL: https://github.com/nbfalcon/ptemplate
;; Package-Requires: ((emacs "25.1") (yasnippet "0.13.0"))
;; Version: 0.1

;;; Commentary:
;; Creating projects can be a lot of work. Cask files need to be set up, a
;; License file must be added, maybe build system files need to be created. A
;; lot of that can be automated, which is what ptemplate does. You can create a
;; set of templates categorized by type/template like in eclipse, and ptemplate
;; will then initialize the project for you. In the template you can have any
;; number of yasnippets or normal files.

;; Security note: yasnippets allow arbitrary code execution, as do .ptemplate.el
;; files. DO NOT RUN UNTRUSTED PTEMPLATES. Ptemplate DOES NOT make ANY special
;; effort to protect against malicious templates.

;;; Code:

(require 'yasnippet)
(require 'cl-lib)

;;; (ptemplate--read-file :: String -> String)
(defun ptemplate--read-file (file)
  "Read FILE and return its contents a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

;;; (ptemplate--snippet-chain :: (Cons String String) | Buffer)
(defvar ptemplate--snippet-chain nil
  "List of (SNIPPET . TARGET) or BUFFER.
Template directories can have any number of yasnippet files.
These need to be filled in by the user. To do this, there is a
snippet chain: a list of snippets and their target files or
buffers. During expansion of a template directory, first all
snippets are gathered into a list, the first snippet of which is
then shown to the user. If the user presses
\\<ptemplate--snippet-chain-mode-map>
\\[ptemplate-snippet-chain-next], the next item in the snippet
chain is displayed. Buffers are appended to this list when the
user presses \\<ptemplate--snippet-chain-mode-map>
\\[ptemplate-snippet-chain-later].")

(defun ptemplate--snippet-chain-continue ()
  "Make the next snippt/buffer in the snippet chain current."
  (when-let ((next (pop ptemplate--snippet-chain)))
    (if (bufferp next)
        (switch-to-buffer next)
      (find-file (cdr next))
      (ptemplate--snippet-chain-mode 1)
      (yas-expand-snippet (ptemplate--read-file (car next))))))

(defun ptemplate-snippet-chain-next ()
  "Save the current buffer and continue in the snippet chain.
The buffer is killed after calling this. If the snippet chain is
empty, do nothing."
  (interactive)
  (save-buffer 0)
  (let ((old-buf (current-buffer)))
    (ptemplate--snippet-chain-continue)
    (kill-buffer old-buf)))

(defun ptemplate-snippet-chain-later ()
  "Save the current buffer to be expanded later.
Use this if you are not sure yet what expansions to use in
templates and want to decide later, after looking at other
templates."
  (interactive)
  (nconc ptemplate--snippet-chain (list (current-buffer)))
  (ptemplate--snippet-chain-continue))

(define-minor-mode ptemplate--snippet-chain-mode
  "Minor mode for template directory snippets.
This mode is only for keybindings."
  :init-value nil
  :lighter nil
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'ptemplate-snippet-chain-next)
            (define-key map (kbd "C-c C-l") #'ptemplate-snippet-chain-later)
            map))

;;; (ptemplate--start-snippet-chain :: [Cons String String | Buffer])
(defun ptemplate--start-snippet-chain (snippets)
  "Start a snippet chain with SNIPPETS.
For details, see `ptemplate--snippet-chain'."
  (let ((first (pop snippets)))
    (find-file (cdr first))
    (yas-expand-snippet (ptemplate--read-file (car first)))
    (setq ptemplate--snippet-chain snippets))
  (ptemplate--snippet-chain-mode 1))

;;; (ptemplate--yasnippet-p :: String -> Bool)
(defun ptemplate--yasnippet-p (file)
  "Check if FILE has a yasnippet extension and nil otherwise."
  (string= (file-name-extension file) "yas"))

(defun ptemplate--autosnippet-p (file)
  "Check if FILE names a non-interactive snippets.
Such snippets should be expanded automatically without user
interaction."
  (string= (file-name-extension file) "autoyas"))

;;; (ptemplate-expand-template :: String -> String)
(defun ptemplate-expand-template (dir target)
  "Expand the template in DIR to TARGET."
  (when (file-directory-p target)
    (user-error "Directory %s already exists" target))

  (make-directory target t)
  (setq target (file-name-as-directory target))
  (with-temp-buffer
    ;; this way, all template files will begin with ./, making them easier to
    ;; copy to target.
    (cd dir)
    (let ((files (directory-files-recursively "." "" t)))
      ;; make directories
      (cl-loop for file in files do
               (when (file-directory-p file)
                   (setq file (file-name-as-directory file)))
               (make-directory (concat target (file-name-directory file)) t))
      (setq files (cl-delete-if #'file-directory-p files))

      (let ((yasnippets
             (cl-loop for file in files if (ptemplate--yasnippet-p file)
                      collect (cons (concat dir file)
                                    (concat target
                                            (file-name-sans-extension file)))))
            (normal-files (cl-delete-if #'ptemplate--yasnippet-p files)))
        (when yasnippets
          (ptemplate--start-snippet-chain yasnippets))
        (dolist (file normal-files)
          (if (ptemplate--autosnippet-p file)
              (with-temp-file (concat target (file-name-sans-extension file))
                (yas-expand-snippet (ptemplate--read-file file)))
            (copy-file file (concat target file))))))))

;;; (ptemplate-template-dirs :: [String])
(defcustom ptemplate-template-dirs '()
  "List of directories containing templates.
Analagous to `yas-snippet-dirs'."
  :group 'ptemplate
  :type '(repeat string))

;;; (ptemplate-find-template :: String -> [String])
(defun ptemplate-find-templates (template)
  "Find TEMPLATE in `ptemplate-template-dirs'.
Template shall be a path of the form \"category/type\". Returns a
list of full paths to the template directory specified by
TEMPLATE. Returns the empty list if TEMPLATE cannot be found."
  (let ((template (file-name-as-directory template))
        (result))
    (dolist (dir ptemplate-template-dirs)
      (let ((template-dir (concat (file-name-as-directory dir) template)))
        (when (file-directory-p template-dir)
          (push template-dir result))))
    (nreverse result)))

(defun ptemplate-find-template (template)
  "Find TEMPLATE in `ptemplate-template-dirs'.
Unlike `ptemplate-find-templates', this function does not return
all occurrences, but only the first."
  (catch 'result
    (dolist (dir ptemplate-template-dirs)
      (let ((template-dir (concat (file-name-as-directory dir) template)))
        (when (file-directory-p template-dir)
          (throw 'result template-dir))))))

(defun ptemplate-list-template-dir (dir)
  "List all templates in directory DIR.
The result is of the form (TYPE ((NAME . PATH)...))...."
  (let* ((type-dirs (directory-files dir t))
         (name-dirs (cl-loop for dir in type-dirs collect (directory-files dir t)))
         (names (mapcar #'file-name-base name-dirs))
         (name-dir-pairs (cl-mapcar #'cons names name-dirs))
         (types (mapcar #'file-name-base type-dirs)))
    (cl-mapcar #'cons types name-dir-pairs)))

(defun ptemplate-list-templates ()
  "List all templates that user has stored.
The result is an alist ((TYPE (NAME . PATH)...)...)."
  (mapcan #'ptemplate-list-template-dir ptemplate-template-dirs))

(defcustom ptemplate-workspace-alist '()
  "Alist mapping between template types and workspace folders."
  :group 'ptemplate
  :type '(alist :key-type (string :tag "Type")
                :value-type (string :tag "Workspace")))

(defun ptemplate-exec-template (template)
  "Expand TEMPLATE in a user-selected directory.
The initial directory is looked up based on
`ptemplate-workspace-alist'. TEMPLATE's type is deduced from its
path, which means that it should have been obtained using
`ptemplate-list-templates', or at least be in a template
directory."
  (let* ((base (directory-file-name template))
         (type (file-name-nondirectory (directory-file-name
                                        (file-name-directory base))))
         (workspace (alist-get type ptemplate-workspace-alist nil nil
                               #'string=))
         (target (read-file-name "Create project: " workspace workspace)))
    (ptemplate-expand-template template target)))

(provide 'ptemplate)
;;; ptemplate.el ends here
