;;; ans-mode.el --- View ANSI art and SAUCE metadata -*- lexical-binding: t -*-

;; Copyright (C) 2026 William Theesfeld <william@theesfeld.net>

;; Author: William Theesfeld <william@theesfeld.net>
;; Keywords: multimedia, faces
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/theesfeld/ans-mode

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Major mode for .ans files.  Opening one draws the artwork instead of
;; the raw escape codes.
;;
;; The stream is interpreted as a CP437 screen: cursor movement, erase,
;; saved cursor positions, a SAUCE column count, and iCE colors.  The
;; default view is a raster of the VGA font (8x16, or 8x8 when SAUCE
;; names a VGA50 font).  Other SAUCE font names, including Amiga and
;; Topaz, use the same 8x16 glyphs.  `t' switches to Unicode text with
;; the same colors, which can be searched and copied.  Saving writes
;; the original bytes back.
;;
;; An ANSiMation is shown as the canvas left after the whole stream.
;; Blink is a color attribute, not an animation.  Pixels are square;
;; the SAUCE aspect flag is reported and does not stretch the raster.
;;
;; Install from MELPA with `M-x package-install', or follow the README
;; for a GitHub checkout and for configuration.  The package has to be
;; active at startup.  Emacs chooses the file coding system before it
;; selects the major mode, and the autoloads register .ans as raw bytes.
;;
;; Keys:
;;   t        toggle raster and text
;;   + / -    scale the raster
;;   0        reset the scale
;;   i        toggle iCE colors
;;   w        set the column count (prefix arg uses SAUCE or 80)
;;   s        show the SAUCE record
;;   n / p    next and previous .ans in this directory
;;   g        reload the file
;;   q        quit the buffer

;;; Code:

(require 'cl-lib)
(require 'ans-render)
(require 'ans-sauce)
(require 'ans-vga)

(defcustom ans-view 'image
  "Initial view for `ans-mode'.
`image' draws a VGA raster.  `text' draws Unicode with VGA colors."
  :type '(choice (const image) (const text))
  :group 'ans)

(defcustom ans-image-scale 2
  "How many screen pixels represent one VGA font pixel.
1 is native size.  2 is easier to read."
  :type 'integer
  :group 'ans)

(defcustom ans-letter-spacing 'auto
  "Character cell width for the raster, in pixels.
`auto' uses 9 when SAUCE requests a 9-pixel font and 8 otherwise.
A 9-pixel cell repeats the rightmost column of CP437 bytes #xC0-#xDF,
which is the VGA box-drawing rule."
  :type '(choice (const auto) (const 8) (const 9))
  :group 'ans)

(defcustom ans-image-max-pixels 8000000
  "Skip the raster when it would contain more than this many pixels.
The text view is used instead."
  :type 'integer
  :group 'ans)

(defcustom ans-text-font "Terminus"
  "Font family for the text view, or nil to keep the default face.
The raster does not use this font."
  :type '(choice (const nil) string)
  :group 'ans)

(defvar-local ans--raw nil
  "Original bytes of the visited ANSI file.")
(put 'ans--raw 'permanent-local t)

(defvar-local ans--grid nil)
(defvar-local ans--ppm nil)
(defvar-local ans--ppm-key nil)
(defvar-local ans--view nil)
(defvar-local ans--scale nil)
(defvar-local ans--width-override nil)
(defvar-local ans--ice-override nil)
(defvar-local ans--image-skip nil)

(defun ans--capture-bytes ()
  "Return the buffer contents as raw bytes."
  (save-restriction
    (widen)
    (let ((contents (buffer-substring-no-properties (point-min) (point-max))))
      (if (multibyte-string-p contents)
          (encode-coding-string contents 'raw-text-unix)
        contents))))

(defun ans--require-buffer ()
  "Signal a user error unless this is an ANSI buffer with its bytes."
  (unless (derived-mode-p 'ans-mode)
    (user-error "Not an ANSI art buffer"))
  (unless ans--raw
    (user-error "ANSI data is not loaded")))

(defun ans--hex (rgb)
  "Format RGB as a #RRGGBB string."
  (format "#%02X%02X%02X" (nth 0 rgb) (nth 1 rgb) (nth 2 rgb)))

(defun ans--face-for (cell)
  "Face plist for CELL, or nil when it matches the buffer default."
  (let* ((fg (ans-color-rgb (ans-cell-fg cell)))
         (bg (ans-color-rgb (ans-cell-bg cell)))
         (underline (ans-cell-underline-p cell))
         (italic (ans-cell-italic-p cell)))
    (if (and (equal fg (aref ans-palette 7))
             (equal bg (aref ans-palette 0))
             (not underline)
             (not italic))
        nil
      (append (list :foreground (ans--hex fg)
                    :background (ans--hex bg))
              (and underline '(:underline t))
              (and italic '(:slant italic))))))

(defun ans--paint-line (start cells)
  "Apply faces to the line of CELLS that begins at START."
  (let ((column 0)
        (columns (length cells)))
    (while (< column columns)
      (let* ((face (ans--face-for (aref cells column)))
             (next (1+ column)))
        (while (and (< next columns)
                    (equal face (ans--face-for (aref cells next))))
          (setq next (1+ next)))
        (when face
          (put-text-property (+ start column) (+ start next) 'face face)
          (put-text-property (+ start column) (+ start next) 'font-lock-face face))
        (setq column next)))))

(defun ans--insert-text (grid)
  "Insert GRID as Unicode text with VGA color faces."
  (if (= (ans-grid-height grid) 0)
      (insert "(empty ANSI)\n")
    (let ((columns (ans-grid-width grid)))
      (dotimes (row (ans-grid-height grid))
        (let* ((cells (aref (ans-grid-rows grid) row))
               (start (point)))
          ;; Insert character by character.  A unibyte string cannot
          ;; hold the CP437 glyphs above U+00FF.
          (dotimes (column columns)
            (insert (ans-cp437-char (ans-cell-char (aref cells column)))))
          (ans--paint-line start cells)
          (insert "\n"))))))

(defun ans--vga-for-sauce (sauce)
  "Return the VGA font SAUCE asks for, or the 8x16 font."
  (let ((name (and sauce (ans-sauce-font sauce)))
        (case-fold-search t))
    (if (and name (string-match-p "vga50\\|vga-50\\|80x50\\|8x8" name))
        (ans-vga-font 8)
      (ans-vga-font 16))))

(defun ans--cell-width (sauce)
  "Pixel width of one character cell for SAUCE."
  (cond
   ((eq ans-letter-spacing 8) 8)
   ((eq ans-letter-spacing 9) 9)
   ((and sauce (eq (ans-sauce-spacing sauce) 9)) 9)
   (t 8)))

(defun ans--scanline (bits fg bg cell-width ninth)
  "Return RGB bytes for one glyph row BITS.
FG and BG are (R G B) lists.  CELL-WIDTH is 8 or 9.  When NINTH is
non-nil the ninth pixel copies the rightmost glyph bit."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (dotimes (x 8)
      (let ((pix (if (zerop (logand bits (ash 1 (- 7 x)))) bg fg)))
        (insert (nth 0 pix) (nth 1 pix) (nth 2 pix))))
    (when (= cell-width 9)
      (let ((pix (if (and ninth (/= 0 (logand bits 1))) fg bg)))
        (insert (nth 0 pix) (nth 1 pix) (nth 2 pix))))
    (buffer-string)))

(defun ans-render-ppm (grid &optional cell-width font)
  "Render GRID to a binary PPM string, or nil when GRID is empty.
CELL-WIDTH is 8 or 9.  FONT defaults from the SAUCE font name."
  (when (> (ans-grid-height grid) 0)
    (let* ((sauce (ans-grid-sauce grid))
           (font (or font (ans--vga-for-sauce sauce)))
           (cell-width (or cell-width (ans--cell-width sauce)))
           (glyph-height (ans-vga-height font))
           (glyphs (ans-vga-glyphs font))
           (columns (ans-grid-width grid))
           (rows (ans-grid-height grid))
           (px-w (* columns cell-width))
           (px-h (* rows glyph-height))
           (cache (make-hash-table :test #'equal)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert (format "P6\n%d %d\n255\n" px-w px-h))
        (dotimes (row rows)
          (let ((cells (aref (ans-grid-rows grid) row)))
            (dotimes (gy glyph-height)
              (dotimes (column columns)
                (let* ((cell (aref cells column))
                       (char (ans-cell-char cell))
                       (bits (aref glyphs (+ (* char glyph-height) gy)))
                       (fg (ans-color-rgb (ans-cell-fg cell)))
                       (bg (ans-color-rgb (ans-cell-bg cell)))
                       (ninth (and (= cell-width 9) (<= #xC0 char #xDF)))
                       (underline (and (ans-cell-underline-p cell)
                                       (= gy (1- glyph-height)))))
                  (when underline
                    (setq bits #xFF
                          ninth t))
                  (let* ((key (list bits fg bg cell-width ninth))
                         (scan (or (gethash key cache)
                                   (puthash key
                                            (ans--scanline bits fg bg cell-width ninth)
                                            cache))))
                    (insert scan)))))))
        (buffer-string)))))

(defun ans--image-block-reason (grid)
  "Why GRID cannot be shown as a raster, or nil."
  (cond
   ((= (ans-grid-height grid) 0) "empty artwork")
   ((not (image-type-available-p 'pbm)) "PPM images are not supported")
   (t
    (let* ((font (ans--vga-for-sauce (ans-grid-sauce grid)))
           (pixels (* (ans-grid-width grid)
                      (ans--cell-width (ans-grid-sauce grid))
                      (ans-grid-height grid)
                      (ans-vga-height font))))
      (when (> pixels ans-image-max-pixels)
        (format "image is %d pixels; limit is %d" pixels ans-image-max-pixels))))))

(defun ans--ensure-ppm (grid)
  "Return the cached PPM for GRID, building it when needed."
  (let* ((sauce (ans-grid-sauce grid))
         (font (ans--vga-for-sauce sauce))
         (cell-width (ans--cell-width sauce))
         (key (list cell-width (ans-vga-height font)
                    (ans-grid-width grid) (ans-grid-height grid)
                    (ans-grid-ice grid))))
    (unless (and ans--ppm (equal ans--ppm-key key))
      (setq ans--ppm (ans-render-ppm grid cell-width font)
            ans--ppm-key key))
    ans--ppm))

(defun ans--insert-image (grid)
  "Insert GRID as one scaled VGA raster."
  (let ((ppm (ans--ensure-ppm grid)))
    (insert-image
     (create-image ppm 'pbm t
                   :scale (max 1 (or ans--scale 1))
                   :transform-smoothing nil))
    (insert "\n")))

(defun ans--who (sauce)
  "Author / group string for SAUCE, or nil."
  (when sauce
    (let ((author (ans-sauce-author sauce))
          (group (ans-sauce-group sauce)))
      (cond
       ((and (not (string-empty-p author)) (not (string-empty-p group)))
        (format "%s / %s" author group))
       ((not (string-empty-p author)) author)
       ((not (string-empty-p group)) group)))))

(defun ans--header-line ()
  "Header line for the current ANSI buffer."
  (if (not (ans-grid-p ans--grid))
      "ANSI"
    (let* ((sauce (ans-grid-sauce ans--grid))
           (title (or (and sauce
                           (not (string-empty-p (ans-sauce-title sauce)))
                           (ans-sauce-title sauce))
                      (and buffer-file-name
                           (file-name-nondirectory buffer-file-name))
                      "(ANSI)"))
           (comments (and sauce (ans-sauce-comments sauce)))
           (parts
            (list title
                  (ans--who sauce)
                  (and sauce
                       (not (string-empty-p (ans-sauce-date sauce)))
                       (ans-sauce-date sauce))
                  (format "%d×%d" (ans-grid-width ans--grid) (ans-grid-height ans--grid))
                  (when (eq ans--view 'image)
                    (format "%d×%d"
                            (ans--cell-width sauce)
                            (ans-vga-height (ans--vga-for-sauce sauce))))
                  (when (ans-grid-ice ans--grid) "iCE")
                  (and sauce
                       (not (string-empty-p (ans-sauce-font sauce)))
                       (ans-sauce-font sauce))
                  (when comments
                    (format "%d comment%s"
                            (length comments)
                            (if (= (length comments) 1) "" "s")))
                  (when (ans-grid-truncated ans--grid) "truncated")
                  ans--image-skip)))
      (mapconcat #'identity (delq nil parts) "  ·  "))))

(defun ans--redisplay ()
  "Draw `ans--grid' into the current buffer."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t))
    (erase-buffer)
    (set-buffer-multibyte t)
    (setq ans--image-skip nil)
    (if (eq ans--view 'text)
        (progn
          (setq cursor-type t)
          (ans--insert-text ans--grid))
      (let ((reason (ans--image-block-reason ans--grid)))
        (if reason
            (progn
              (setq ans--image-skip reason
                    ans--view 'text
                    cursor-type t)
              (ans--insert-text ans--grid)
              (message "Showing text: %s" reason))
          (setq cursor-type nil)
          (ans--insert-image ans--grid))))
    (goto-char (point-min))
    (set-buffer-modified-p nil)))

(defun ans--show ()
  "Render `ans--raw' and display it."
  (setq ans--grid
        (ans-render-bytes ans--raw
                          :width ans--width-override
                          :ice (or ans--ice-override 'auto))
        ans--ppm nil
        ans--ppm-key nil)
  (ans--redisplay))

(defun ans--apply-faces ()
  "Give this buffer a black background and, when available, the text font."
  (ignore-errors
    (face-remap-add-relative 'default
                             :background "#000000"
                             :foreground "#AAAAAA")
    (when (and ans-text-font
               (display-graphic-p)
               (find-font (font-spec :family ans-text-font)))
      (face-remap-add-relative 'default :family ans-text-font))))

(defun ans--write-original ()
  "Write the original ANSI bytes back to the visited file."
  (unless buffer-file-name
    (user-error "No file associated with this buffer"))
  (unless ans--raw
    (user-error "Original ANSI bytes are missing"))
  (let ((coding-system-for-write 'no-conversion))
    (write-region ans--raw nil buffer-file-name nil 'silent))
  t)

(defun ans--revert (&rest _)
  "Reload the visited ANSI file and draw it again."
  (let ((file buffer-file-name)
        (inhibit-read-only t)
        (coding-system-for-read 'no-conversion))
    (unless file
      (user-error "No file associated with this buffer"))
    (erase-buffer)
    (set-buffer-multibyte nil)
    (insert-file-contents file)
    (setq ans--raw (ans--capture-bytes)
          ans--grid nil
          ans--ppm nil
          ans--ppm-key nil)
    (ans--show)
    (set-visited-file-modtime)
    (set-buffer-modified-p nil)))

(defun ans-toggle-view ()
  "Toggle between the VGA raster and the Unicode text view."
  (interactive)
  (ans--require-buffer)
  (setq ans--view (if (eq ans--view 'image) 'text 'image))
  (ans--redisplay))

(defun ans-toggle-ice ()
  "Toggle iCE colors and draw the file again."
  (interactive)
  (ans--require-buffer)
  (setq ans--ice-override (if (ans-grid-ice ans--grid) 'off 'on))
  (ans--show)
  (message "iCE colors %s" (if (ans-grid-ice ans--grid) "on" "off")))

(defun ans-set-width (width)
  "Draw this file WIDTH columns wide.
A prefix argument, or WIDTH 0, follows SAUCE or uses 80."
  (interactive
   (list
    (if current-prefix-arg
        nil
      (read-number "Columns (0 uses SAUCE or 80): "
                   (or (and ans--grid (ans-grid-width ans--grid)) 80)))))
  (ans--require-buffer)
  (when (and width (or (< width 0) (> width ans-max-columns)))
    (user-error "Columns must be 0 to %d" ans-max-columns))
  (setq ans--width-override (and width (> width 0) width))
  (ans--show))

(defun ans--adjust-scale (delta)
  "Add DELTA to the raster scale, keeping it between 1 and 8."
  (ans--require-buffer)
  (setq ans--scale (max 1 (min 8 (+ (or ans--scale 1) delta))))
  (when (eq ans--view 'image)
    (ans--redisplay))
  (message "Scale %d" ans--scale))

(defun ans-increase-scale ()
  "Make the raster one step larger."
  (interactive)
  (ans--adjust-scale 1))

(defun ans-decrease-scale ()
  "Make the raster one step smaller."
  (interactive)
  (ans--adjust-scale -1))

(defun ans-reset-scale ()
  "Restore the raster scale to `ans-image-scale'."
  (interactive)
  (ans--require-buffer)
  (setq ans--scale (max 1 ans-image-scale))
  (when (eq ans--view 'image)
    (ans--redisplay))
  (message "Scale %d" ans--scale))

(defun ans--other-file (step)
  "Visit the .ans file STEP places from this one in the same directory."
  (ans--require-buffer)
  (unless buffer-file-name
    (user-error "Buffer is not visiting a file"))
  (let* ((dir (file-name-directory (expand-file-name buffer-file-name)))
         (files (sort (directory-files dir t "\\.[aA][nN][sS]\\'" t)
                      #'string-lessp))
         (current (expand-file-name buffer-file-name))
         (index (cl-position current files :test #'file-equal-p)))
    (unless index
      (user-error "This file is not in the ANSI list"))
    (let ((next (+ index step)))
      (if (or (< next 0) (>= next (length files)))
          (message (if (> step 0) "Last ANSI file" "First ANSI file"))
        (find-alternate-file (nth next files))))))

(defun ans-next-file ()
  "Visit the next .ans file in this directory."
  (interactive)
  (ans--other-file 1))

(defun ans-previous-file ()
  "Visit the previous .ans file in this directory."
  (interactive)
  (ans--other-file -1))

(defun ans--sauce-line (label value)
  "Print one LABEL and VALUE line into the SAUCE buffer."
  (princ (format "%-18s %s\n" label (if value value ""))))

(defun ans-show-sauce ()
  "Show the SAUCE record and the rendered size."
  (interactive)
  (ans--require-buffer)
  (unless ans--grid
    (ans--show))
  (let ((grid ans--grid)
        (sauce (ans-grid-sauce ans--grid)))
    (with-help-window "*ANSI SAUCE*"
      (if (not sauce)
          (princ (format "No SAUCE record.\n\nRendered: %d×%d\niCE colors: %s\n"
                         (ans-grid-width grid)
                         (ans-grid-height grid)
                         (if (ans-grid-ice grid) "yes" "no")))
        (ans--sauce-line "Title" (ans-sauce-title sauce))
        (ans--sauce-line "Author" (ans-sauce-author sauce))
        (ans--sauce-line "Group" (ans-sauce-group sauce))
        (ans--sauce-line "Date" (ans-sauce-date sauce))
        (ans--sauce-line "Type" (ans-sauce-type-label sauce))
        (ans--sauce-line "Font" (ans-sauce-font sauce))
        (ans--sauce-line "SAUCE size"
                         (format "%s×%s"
                                 (or (ans-sauce-columns sauce) "default")
                                 (or (ans-sauce-declared-rows sauce) "unspecified")))
        (ans--sauce-line "Rendered"
                         (format "%d×%d"
                                 (ans-grid-width grid)
                                 (ans-grid-height grid)))
        (ans--sauce-line "iCE colors" (if (ans-sauce-ice sauce) "yes" "no"))
        (ans--sauce-line "Letter spacing"
                         (pcase (ans-sauce-spacing sauce)
                           (8 "8-pixel")
                           (9 "9-pixel")
                           (_ "legacy")))
        (ans--sauce-line "Aspect" (ans-sauce-aspect sauce))
        (ans--sauce-line "File size" (format "%d" (ans-sauce-file-size sauce)))
        (princ "\nComments:\n")
        (if (ans-sauce-comments sauce)
            (dolist (comment (ans-sauce-comments sauce))
              (princ (format "  %s\n" comment)))
          (princ "  (none)\n"))))))

(defvar ans-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "t") #'ans-toggle-view)
    (define-key map (kbd "i") #'ans-toggle-ice)
    (define-key map (kbd "w") #'ans-set-width)
    (define-key map (kbd "s") #'ans-show-sauce)
    (define-key map (kbd "n") #'ans-next-file)
    (define-key map (kbd "p") #'ans-previous-file)
    (define-key map (kbd "+") #'ans-increase-scale)
    (define-key map (kbd "-") #'ans-decrease-scale)
    (define-key map (kbd "0") #'ans-reset-scale)
    (define-key map (kbd "SPC") #'scroll-up-command)
    (define-key map (kbd "S-SPC") #'scroll-down-command)
    (define-key map (kbd "DEL") #'scroll-down-command)
    map)
  "Keymap for `ans-mode'.")

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.[aA][nN][sS]\\'" . ans-mode))
;;;###autoload
(add-to-list 'auto-coding-alist '("\\.[aA][nN][sS]\\'" . no-conversion))
;;;###autoload
(add-to-list 'inhibit-local-variables-regexps "\\.[aA][nN][sS]\\'")

;;;###autoload
(define-derived-mode ans-mode special-mode "ANS"
  "Major mode for viewing ANSI art (.ans) and SAUCE metadata.

The buffer shows a VGA raster, or Unicode text with the same colors.
Saving writes the original bytes.

\\{ans-mode-map}"
  (unless ans--raw
    (setq ans--raw (ans--capture-bytes)))
  (setq ans--grid nil
        ans--ppm nil
        ans--ppm-key nil
        ans--image-skip nil
        ans--view (if (eq ans-view 'text) 'text 'image)
        ans--scale (max 1 ans-image-scale))
  (setq-local local-enable-local-variables nil)
  (setq-local buffer-file-coding-system 'no-conversion)
  (setq-local buffer-undo-list t)
  (setq-local truncate-lines t)
  (setq-local line-spacing 0)
  (setq-local word-wrap nil)
  (setq-local show-trailing-whitespace nil)
  (setq-local nobreak-char-display nil)
  (setq-local revert-buffer-function #'ans--revert)
  (setq-local header-line-format '(:eval (ans--header-line)))
  (add-hook 'write-contents-functions #'ans--write-original nil t)
  (when (bound-and-true-p whitespace-mode)
    (whitespace-mode -1))
  (when font-lock-mode
    (font-lock-mode -1))
  (ans--apply-faces)
  (ans--show)
  (setq mode-name '(:eval (if (eq ans--view 'text) "ANS-Text" "ANS"))))

(provide 'ans-mode)
;;; ans-mode.el ends here
