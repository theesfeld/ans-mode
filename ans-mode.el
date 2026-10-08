;;; ans-mode.el --- View and edit ANSI art and SAUCE metadata -*- lexical-binding: t -*-

;; Copyright (C) 2026 William Theesfeld <william@theesfeld.net>

;; Author: William Theesfeld <william@theesfeld.net>
;; Keywords: multimedia, faces
;; Version: 0.2.0
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
;; the same colors, which can be searched and copied.
;;
;; `e' edits the screen.  Typed characters replace the cell under the
;; cursor and use the current pen.  Saving an edited screen writes
;; ANSi for that grid and keeps the SAUCE title, author, and comments.
;; Saving before any edit writes the original bytes, including an
;; ANSiMation stream.
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
;;   e        edit the screen
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
(defvar-local ans--edited nil
  "Non-nil when the screen has been edited and should be saved as ANSi.")
(defvar-local ans--cursor-row 0
  "Cursor row while editing, counting from 0.")
(defvar-local ans--cursor-col 0
  "Cursor column while editing, counting from 0.")
(defvar-local ans--pen-fg 7
  "Foreground palette index, 256-color index, or (R G B) list.")
(defvar-local ans--pen-bg 0
  "Background palette index, 256-color index, or (R G B) list.")
(defvar-local ans--pen-underline nil
  "Non-nil when the pen underlines new cells.")

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

(defun ans--color-label (color)
  "Short label for COLOR, a palette index or an (R G B) list."
  (cond
   ((integerp color) (format "%d" color))
   ((and (consp color) (nth 2 color))
    (apply #'format "#%02X%02X%02X" color))
   (t "?")))

(defun ans--ppm-with-cursor (ppm grid)
  "Return PPM with the edit cursor inverted, or PPM when it has no cell."
  (let ((row ans--cursor-row)
        (column ans--cursor-col))
    (if (or (not ppm)
            (< row 0) (>= row (ans-grid-height grid))
            (< column 0) (>= column (ans-grid-width grid)))
        ppm
      (let* ((sauce (ans-grid-sauce grid))
             (cell-width (ans--cell-width sauce))
             (glyph-height (ans-vga-height (ans--vga-for-sauce sauce)))
             (px-w (* (ans-grid-width grid) cell-width))
             (copy (copy-sequence ppm))
             (x0 (* column cell-width))
             (y0 (* row glyph-height)))
        (string-match "\\`P6\n[0-9]+ [0-9]+\n255\n" copy)
        (let ((base (match-end 0)))
          (dotimes (dy glyph-height)
            (dotimes (dx cell-width)
              (let ((index (+ base (* (+ (* (+ y0 dy) px-w) (+ x0 dx)) 3))))
                (aset copy index (- 255 (aref copy index)))
                (aset copy (1+ index) (- 255 (aref copy (1+ index))))
                (aset copy (+ index 2) (- 255 (aref copy (+ index 2))))))))
        copy))))

(defun ans--insert-image (grid)
  "Insert GRID as one scaled VGA raster."
  (let ((ppm (ans--ensure-ppm grid)))
    (when (bound-and-true-p ans-edit-mode)
      (setq ppm (ans--ppm-with-cursor ppm grid)))
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
                  ans--image-skip
                  (when (bound-and-true-p ans-edit-mode)
                    (format "edit %d,%d  pen %s/%s%s"
                            (1+ ans--cursor-row)
                            (1+ ans--cursor-col)
                            (ans--color-label ans--pen-fg)
                            (ans--color-label ans--pen-bg)
                            (if ans--pen-underline " ul" ""))))))
      (mapconcat #'identity (delq nil parts) "  ·  "))))

(defun ans--redisplay ()
  "Draw `ans--grid' into the current buffer."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        ;; The grid is the document.  Cell edits keep their own undo
        ;; entries, so the redraw must not record a buffer-text change.
        (buffer-undo-list t))
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
    (if (bound-and-true-p ans-edit-mode)
        (ans--goto-cursor)
      (goto-char (point-min)))
    (set-buffer-modified-p (and ans--edited t))))

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
  "Write this ANSI buffer back to the visited file.
An edited screen is encoded as ANSi.  An unedited buffer writes the
bytes that were loaded, so an ANSiMation stream stays intact."
  (unless buffer-file-name
    (user-error "No file associated with this buffer"))
  (unless ans--raw
    (user-error "Original ANSI bytes are missing"))
  (when ans--edited
    (setq ans--raw (ans-encode-grid ans--grid)
          ans--edited nil))
  (let ((coding-system-for-write 'no-conversion))
    (write-region ans--raw nil buffer-file-name nil 'silent))
  (set-buffer-modified-p nil)
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
          ans--ppm-key nil
          ans--edited nil
          ans--cursor-row 0
          ans--cursor-col 0)
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
  "Toggle iCE colors and draw the file again.
After an edit, the cells keep their colors and the SAUCE flag changes.
Before an edit, the file is interpreted again."
  (interactive)
  (ans--require-buffer)
  (if ans--edited
      (progn
        (setf (ans-grid-ice ans--grid) (not (ans-grid-ice ans--grid)))
        (setq ans--ice-override (if (ans-grid-ice ans--grid) 'on 'off)
              ans--ppm nil
              ans--ppm-key nil)
        (ans--redisplay))
    (setq ans--ice-override (if (ans-grid-ice ans--grid) 'off 'on))
    (ans--show))
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
  (if ans--edited
      (let* ((sauce (ans-grid-sauce ans--grid))
             (columns (or (and width (> width 0) width)
                          (and sauce (ans-sauce-columns sauce))
                          80)))
        (ans-grid-set-width ans--grid columns)
        (setq ans--width-override columns
              ans--cursor-col (min ans--cursor-col (1- columns))
              ans--ppm nil
              ans--ppm-key nil)
        (ans--redisplay))
    (setq ans--width-override (and width (> width 0) width))
    (ans--show)))

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

(defun ans--cell-at (row column)
  "Return the cell at ROW and COLUMN, or nil when that row is absent."
  (when (and ans--grid
             (>= row 0) (< row (ans-grid-height ans--grid))
             (>= column 0) (< column (ans-grid-width ans--grid)))
    (ans-grid-cell ans--grid row column)))

(defun ans--cell-position (row column)
  "Return the buffer position of ROW and COLUMN in the text view."
  (let ((width (ans-grid-width ans--grid))
        (height (ans-grid-height ans--grid)))
    (if (or (<= height 0) (>= row height))
        (point-max)
      (+ (point-min)
         (* row (1+ width))
         (max 0 (min column (1- width)))))))

(defun ans--goto-cursor ()
  "Move point to the edit cursor in the text view."
  (goto-char (ans--cell-position ans--cursor-row ans--cursor-col)))

(defun ans--show-cursor ()
  "Show the edit cursor in the current view."
  (if (eq ans--view 'image)
      (ans--redisplay)
    (ans--goto-cursor)))

(defun ans--move-cursor (row column)
  "Move the edit cursor to ROW and COLUMN."
  (setq ans--cursor-row row ans--cursor-col column)
  (ans--show-cursor))

(defun ans--replace-cell-text (row column)
  "Update the text-view glyph at ROW and COLUMN from the grid."
  (let* ((cells (aref (ans-grid-rows ans--grid) row))
         (start (ans--cell-position row 0))
         (cell (aref cells column))
         (inhibit-read-only t)
         (inhibit-modification-hooks t)
         ;; Cell edits undo through `ans--restore-screen'.  The redraw
         ;; is not a separate change to the document.
         (buffer-undo-list t))
    (goto-char (+ start column))
    (delete-char 1)
    (insert (ans-cp437-char (ans-cell-char cell)))
    (remove-text-properties start (+ start (length cells))
                            '(face nil font-lock-face nil))
    (ans--paint-line start cells)))

(declare-function undo-auto--undoable-change "simple" ())

(defun ans--change-cell (row column cell)
  "Store CELL at ROW and COLUMN, draw it, and record undo."
  (let* ((height (ans-grid-height ans--grid))
         (grew (or (= height 0) (>= row height)))
         (was-edited ans--edited))
    (when (eq buffer-undo-list t)
      (setq buffer-undo-list nil))
    (undo-boundary)
    (push (list 'apply 'ans--restore-screen
                row column (ans--cell-at row column) height was-edited)
          buffer-undo-list)
    (ans-grid-set-cell ans--grid row column cell)
    (setq ans--edited t
          ans--ppm nil
          ans--ppm-key nil)
    (if (and (eq ans--view 'text) (not grew))
        (ans--replace-cell-text row column)
      (ans--redisplay))
    (set-buffer-modified-p t)
    ;; The redraw hides the buffer change from Emacs, which would
    ;; otherwise leave the next `undo' with no boundary to stop at.
    (undo-auto--undoable-change)))

(defun ans--restore-screen (row column cell height edited)
  "Undo helper.  Restore CELL at ROW, COLUMN and the screen HEIGHT.
EDITED is the previous value of `ans--edited'."
  (let ((redo-cell (ans--cell-at row column))
        (redo-height (ans-grid-height ans--grid))
        (redo-edited ans--edited))
    (push (list 'apply 'ans--restore-screen
                row column redo-cell redo-height redo-edited)
          buffer-undo-list)
    (while (< (ans-grid-height ans--grid) (max height (if cell (1+ row) height)))
      (ans-grid-set-cell ans--grid (ans-grid-height ans--grid) 0 nil))
    (when (and cell (< row (ans-grid-height ans--grid)))
      (ans-grid-set-cell ans--grid row column cell))
    (when (and (null cell) (< row (ans-grid-height ans--grid)))
      (ans-grid-set-cell ans--grid row column nil))
    (when (< height (ans-grid-height ans--grid))
      (ans-grid-set-height ans--grid height))
    (setq ans--cursor-row (if (> height 0) (min row (1- height)) 0)
          ans--cursor-col column
          ans--edited edited
          ans--ppm nil
          ans--ppm-key nil)
    (ans--redisplay)
    (set-buffer-modified-p (and edited t))
    (undo-auto--undoable-change)))

(defun ans--extend-to-cursor ()
  "Add an empty row when the cursor has moved past the last row."
  (when (>= ans--cursor-row (ans-grid-height ans--grid))
    (ans--change-cell ans--cursor-row 0 nil)))

(defun ans--advance-cursor ()
  "Move the cursor to the next cell, wrapping at the right edge."
  (if (< ans--cursor-col (1- (ans-grid-width ans--grid)))
      (setq ans--cursor-col (1+ ans--cursor-col))
    (if (>= (1+ ans--cursor-row) ans-max-rows)
        (message "Last cell")
      (setq ans--cursor-col 0
            ans--cursor-row (1+ ans--cursor-row)))))

(defun ans--require-edit ()
  "Signal a user error unless the screen is being edited."
  (ans--require-buffer)
  (unless (bound-and-true-p ans-edit-mode)
    (user-error "Press e to edit this screen")))

(defun ans--event-character ()
  "Return the character that invoked this command."
  (cond
   ((characterp last-command-event) last-command-event)
   ((and (eventp last-command-event)
         (characterp (event-basic-type last-command-event)))
    (event-basic-type last-command-event))
   (t (user-error "Not a character"))))

(defun ans--pen-cell (byte)
  "Return a cell for CP437 BYTE using the current pen."
  (ans-make-cell byte ans--pen-fg ans--pen-bg (if ans--pen-underline 1 0)))

(defun ans--read-palette (prompt current)
  "Read a VGA palette index, prompting with PROMPT.
CURRENT is the value shown as the default."
  (let ((n (truncate (read-number prompt (if (integerp current) current 7)))))
    (unless (<= 0 n 15)
      (user-error "Color is a number from 0 to 15"))
    n))

(defun ans-insert-char ()
  "Replace the current cell with the typed glyph and move to the next cell."
  (interactive)
  (ans--require-edit)
  (let* ((char (ans--event-character))
         (byte (ans-cp437-byte char)))
    (unless byte
      (user-error "No CP437 glyph for `%c'" char))
    (when (memq byte ans-stream-controls)
      (user-error "That glyph cannot be stored in an ANSI stream"))
    (when (>= ans--cursor-row ans-max-rows)
      (user-error "ANSI screen is limited to %d rows" ans-max-rows))
    (ans--change-cell ans--cursor-row ans--cursor-col (ans--pen-cell byte))
    (ans--advance-cursor)
    (ans--show-cursor)))

(defun ans-backward-delete-cell ()
  "Move to the previous cell and paint it with a space in the current pen."
  (interactive)
  (ans--require-edit)
  (cond
   ((> ans--cursor-col 0)
    (setq ans--cursor-col (1- ans--cursor-col)))
   ((> ans--cursor-row 0)
    (setq ans--cursor-row (1- ans--cursor-row)
          ans--cursor-col (1- (ans-grid-width ans--grid))))
   (t (user-error "First cell")))
  (ans--change-cell ans--cursor-row ans--cursor-col (ans--pen-cell 32))
  (ans--show-cursor))

(defun ans-newline-cell ()
  "Move the cursor to the first column of the next row."
  (interactive)
  (ans--require-edit)
  (if (>= (1+ ans--cursor-row) ans-max-rows)
      (message "Last row")
    (setq ans--cursor-row (1+ ans--cursor-row)
          ans--cursor-col 0)
    (ans--extend-to-cursor)
    (ans--show-cursor)))

(defun ans-forward-cell (&optional n)
  "Move the cursor N cells to the right, wrapping onto the next row."
  (interactive "p")
  (ans--require-edit)
  (dotimes (_ (max 1 (or n 1)))
    (if (< ans--cursor-col (1- (ans-grid-width ans--grid)))
        (setq ans--cursor-col (1+ ans--cursor-col))
      (if (>= (1+ ans--cursor-row) ans-max-rows)
          (message "Last cell")
        (setq ans--cursor-col 0
              ans--cursor-row (1+ ans--cursor-row))
        (ans--extend-to-cursor))))
  (ans--show-cursor))

(defun ans-backward-cell (&optional n)
  "Move the cursor N cells to the left, wrapping onto the previous row."
  (interactive "p")
  (ans--require-edit)
  (dotimes (_ (max 1 (or n 1)))
    (cond
     ((> ans--cursor-col 0)
      (setq ans--cursor-col (1- ans--cursor-col)))
     ((> ans--cursor-row 0)
      (setq ans--cursor-row (1- ans--cursor-row)
            ans--cursor-col (1- (ans-grid-width ans--grid))))
     (t (message "First cell"))))
  (ans--show-cursor))

(defun ans-previous-line-cell (&optional n)
  "Move the cursor N rows up, staying in this column."
  (interactive "p")
  (ans--require-edit)
  (setq ans--cursor-row (max 0 (- ans--cursor-row (max 1 (or n 1)))))
  (ans--show-cursor))

(defun ans-next-line-cell (&optional n)
  "Move the cursor N rows down, adding a row when the cursor passes the end."
  (interactive "p")
  (ans--require-edit)
  (let ((target (+ ans--cursor-row (max 1 (or n 1)))))
    (when (>= target ans-max-rows)
      (setq target (1- ans-max-rows))
      (message "Last row"))
    (while (< ans--cursor-row target)
      (setq ans--cursor-row (1+ ans--cursor-row))
      (ans--extend-to-cursor)))
  (ans--show-cursor))

(defun ans-beginning-of-line-cell ()
  "Move the cursor to the first column of this row."
  (interactive)
  (ans--require-edit)
  (ans--move-cursor ans--cursor-row 0))

(defun ans-end-of-line-cell ()
  "Move the cursor to the last drawn cell on this row."
  (interactive)
  (ans--require-edit)
  (let ((column 0)
        (cells (and (< ans--cursor-row (ans-grid-height ans--grid))
                    (aref (ans-grid-rows ans--grid) ans--cursor-row))))
    (when cells
      (let ((index (1- (length cells))))
        (while (and (> index 0) (ans-cell-default-p (aref cells index)))
          (setq index (1- index)))
        (setq column (if (ans-cell-default-p (aref cells index)) 0 index))))
    (ans--move-cursor ans--cursor-row column)))

(defun ans-tab-cell ()
  "Move the cursor to the next eighth column."
  (interactive)
  (ans--require-edit)
  (let* ((width (ans-grid-width ans--grid))
         (step (- 8 (mod ans--cursor-col 8)))
         (next (min (1- width) (+ ans--cursor-col (if (zerop step) 8 step)))))
    (ans--move-cursor ans--cursor-row next)))

(defun ans-set-pen-foreground (color)
  "Set the pen foreground to COLOR, a VGA index from 0 to 15."
  (interactive
   (list (ans--read-palette "Foreground (0-15): " ans--pen-fg)))
  (ans--require-edit)
  (setq ans--pen-fg color)
  (ans--show-cursor)
  (message "Foreground %s" (ans--color-label color)))

(defun ans-set-pen-background (color)
  "Set the pen background to COLOR, a VGA index from 0 to 15."
  (interactive
   (list (ans--read-palette "Background (0-15): " ans--pen-bg)))
  (ans--require-edit)
  (setq ans--pen-bg color)
  (ans--show-cursor)
  (message "Background %s" (ans--color-label color)))

(defun ans-toggle-pen-underline ()
  "Toggle underlining for cells typed from now on."
  (interactive)
  (ans--require-edit)
  (setq ans--pen-underline (not ans--pen-underline))
  (message "Underline %s" (if ans--pen-underline "on" "off")))

(defun ans-pick-pen ()
  "Copy the current cell's colors and underline into the pen."
  (interactive)
  (ans--require-edit)
  (let ((cell (ans--cell-at ans--cursor-row ans--cursor-col)))
    (setq ans--pen-fg (ans-cell-fg cell)
          ans--pen-bg (ans-cell-bg cell)
          ans--pen-underline (ans-cell-underline-p cell))
    (message "Pen %s on %s%s"
             (ans--color-label ans--pen-fg)
             (ans--color-label ans--pen-bg)
             (if ans--pen-underline ", underline" ""))))

(defun ans--image-click (event)
  "Move the cursor to the raster cell clicked by EVENT."
  (let* ((xy (posn-object-x-y (event-start event)))
         (scale (max 1 (or ans--scale 1)))
         (sauce (ans-grid-sauce ans--grid))
         (cell-width (ans--cell-width sauce))
         (glyph-height (max 1 (ans-vga-height (ans--vga-for-sauce sauce))))
         (width (ans-grid-width ans--grid))
         (height (ans-grid-height ans--grid)))
    (if (or (not xy) (<= height 0))
        (message "Click the picture")
      (ans--move-cursor
       (min (1- height)
            (max 0 (truncate (/ (cdr xy) (* scale glyph-height)))))
       (min (1- width)
            (max 0 (truncate (/ (car xy) (* scale cell-width)))))))))

(defun ans-mouse-set-cursor (event)
  "Move the edit cursor to the cell clicked by EVENT."
  (interactive "e")
  (ans--require-edit)
  (if (eq ans--view 'image)
      (ans--image-click event)
    (mouse-set-point event)
    (let* ((width (ans-grid-width ans--grid))
           (height (ans-grid-height ans--grid))
           (stride (1+ width))
           (index (max 0 (- (point) (point-min)))))
      (if (<= height 0)
          (ans--move-cursor 0 0)
        (let ((row (min (1- height) (/ index stride)))
              (column (% index stride)))
          (when (>= column width)
            (setq column (1- width)))
          (ans--move-cursor row column))))))

(defun ans--reject-raw-edit (_beg _end)
  "Refuse a direct change to the displayed text.
The grid is the document.  Typed characters replace one cell, and
undo restores a cell.  A command that edits the buffer text would
leave the picture and the grid different."
  (unless (or inhibit-read-only (bound-and-true-p undo-in-progress))
    (user-error "The screen is edited one cell at a time")))

(defvar ans-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ans-edit-mode)
    (define-key map (kbd "C-c C-f") #'ans-set-pen-foreground)
    (define-key map (kbd "C-c C-b") #'ans-set-pen-background)
    (define-key map (kbd "C-c C-p") #'ans-pick-pen)
    (define-key map (kbd "C-c C-u") #'ans-toggle-pen-underline)
    (define-key map (kbd "C-c C-t") #'ans-toggle-view)
    (define-key map (kbd "C-c C-i") #'ans-toggle-ice)
    (define-key map (kbd "C-c C-s") #'ans-show-sauce)
    (define-key map (kbd "C-c C-w") #'ans-set-width)
    (define-key map (kbd "C-c C-r") #'revert-buffer)
    (define-key map [remap self-insert-command] #'ans-insert-char)
    (dotimes (i 95)
      (define-key map (vector (+ 32 i)) #'ans-insert-char))
    (define-key map (kbd "RET") #'ans-newline-cell)
    (define-key map (kbd "TAB") #'ans-tab-cell)
    (define-key map (kbd "DEL") #'ans-backward-delete-cell)
    (define-key map (kbd "<backspace>") #'ans-backward-delete-cell)
    (define-key map (kbd "<left>") #'ans-backward-cell)
    (define-key map (kbd "<right>") #'ans-forward-cell)
    (define-key map (kbd "<up>") #'ans-previous-line-cell)
    (define-key map (kbd "<down>") #'ans-next-line-cell)
    (define-key map (kbd "C-b") #'ans-backward-cell)
    (define-key map (kbd "C-f") #'ans-forward-cell)
    (define-key map (kbd "C-p") #'ans-previous-line-cell)
    (define-key map (kbd "C-n") #'ans-next-line-cell)
    (define-key map (kbd "C-a") #'ans-beginning-of-line-cell)
    (define-key map (kbd "C-e") #'ans-end-of-line-cell)
    (define-key map (kbd "<home>") #'ans-beginning-of-line-cell)
    (define-key map (kbd "<end>") #'ans-end-of-line-cell)
    (define-key map [mouse-1] #'ans-mouse-set-cursor)
    map)
  "Keymap for `ans-edit-mode'.")

(define-minor-mode ans-edit-mode
  "Edit the ANSI screen one cell at a time.
Typed characters replace the cell under the cursor and use the pen.
`C-c C-f' and `C-c C-b' set the pen colors.  `C-c C-p' copies the
colors from the current cell.  `C-c C-u' toggles underline.  `C-c C-c'
leaves this mode.

While this mode is on, letters type glyphs.  Viewer commands are on
the `C-c C-' prefix: `t' switches view, `i' toggles iCE colors, `s'
shows SAUCE, `w' sets the width, and `r' reloads the file."
  :lighter " Edit"
  :keymap ans-edit-mode-map
  (if ans-edit-mode
      (progn
        (unless (derived-mode-p 'ans-mode)
          (setq ans-edit-mode nil)
          (user-error "ANS editing works in an ANSI art buffer"))
        (when (eq buffer-undo-list t)
          (setq buffer-undo-list nil))
        ;; `undo' and `undo-redo' refuse a read-only buffer.  The hook
        ;; still blocks raw text edits, so the grid stays the document.
        (setq buffer-read-only nil)
        (add-hook 'before-change-functions #'ans--reject-raw-edit nil t)
        (setq ans--cursor-col
              (min ans--cursor-col
                   (1- (max 1 (ans-grid-width ans--grid)))))
        (ans--redisplay)
        (message "Editing.  C-c C-c leaves edit mode.  C-c C-f sets the foreground."))
    (remove-hook 'before-change-functions #'ans--reject-raw-edit t)
    (when (derived-mode-p 'ans-mode)
      (setq buffer-read-only t)
      (ans--redisplay))))

(defvar ans-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "e") #'ans-edit-mode)
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
  "Major mode for viewing and editing ANSI art (.ans) and SAUCE metadata.

The buffer shows a VGA raster, or Unicode text with the same colors.
`e' edits the screen one cell at a time.  Saving an edited screen
writes ANSi for that grid.  Saving before any edit writes the original
bytes.

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
