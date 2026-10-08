;;; ans-render.el --- Render ANSI art into a character grid -*- lexical-binding: t -*-

;; Copyright (C) 2026 William Theesfeld <william@theesfeld.net>

;; Author: William Theesfeld <william@theesfeld.net>
;; Keywords: multimedia

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Turn a CP437 ANSI byte stream into a grid of cells.
;;
;; The stream is the artwork, not a linear text file.  Cursor
;; positioning, erase, and saved cursor positions write into a fixed
;; number of columns.  A character placed in the last column does not
;; wrap until the next printable character.  CR and LF cancel that
;; pending wrap, which is how ANSI.SYS avoids a blank line after a
;; full 80-column row.
;;
;; Colors are the VGA palette.  Bold brightens foreground indexes 0-7.
;; When iCE colors are on, blink brightens the background the same way
;; and is not stored.  When iCE colors are off, blink stays on the cell
;; and is written back as SGR 5.  The picture is not animated.
;; Bytes other than CR, LF, TAB, ESC, and SUB (0x1A) are CP437 glyphs,
;; including the classic control pictures.

;;; Code:

(require 'cl-lib)
(require 'ans-sauce)

(defconst ans-max-columns 4096
  "Largest column count `ans-render-bytes' will use.")

(defcustom ans-max-rows 10000
  "Largest number of rows `ans-render-bytes' will keep.
A cursor move past this row clamps there and marks the grid truncated."
  :type 'integer
  :group 'ans)

(defconst ans-palette
  [(0 0 0)
   (170 0 0)
   (0 170 0)
   (170 85 0)
   (0 0 170)
   (170 0 170)
   (0 170 170)
   (170 170 170)
   (85 85 85)
   (255 85 85)
   (85 255 85)
   (255 255 85)
   (85 85 255)
   (255 85 255)
   (85 255 255)
   (255 255 255)]
  "VGA ANSI palette.  0 is black, 7 is light gray, 8-15 are bright.")

(cl-defstruct (ans-grid (:constructor ans-grid--make) (:copier nil))
  "A rendered ANSI screen."
  width height ice sauce rows truncated)

(defun ans-color-rgb (color)
  "Return COLOR as a list (R G B).
COLOR is a palette or xterm-256 index, or an (R G B) list."
  (cond
   ((consp color)
    (list (max 0 (min 255 (or (nth 0 color) 0)))
          (max 0 (min 255 (or (nth 1 color) 0)))
          (max 0 (min 255 (or (nth 2 color) 0)))))
   ((and (integerp color) (<= 0 color 15))
    (aref ans-palette color))
   ((and (integerp color) (<= 16 color 231))
    (let* ((n (- color 16))
           (levels [0 95 135 175 215 255]))
      (list (aref levels (/ n 36))
            (aref levels (/ (% n 36) 6))
            (aref levels (% n 6)))))
   ((and (integerp color) (<= 232 color 255))
    (let ((value (+ 8 (* (- color 232) 10))))
      (list value value value)))
   (t (aref ans-palette 7))))

(defun ans-grid-cell (grid row column)
  "Return the cell at ROW and COLUMN in GRID, or nil when unwritten.
A nil cell is a space with light gray on black."
  (aref (aref (ans-grid-rows grid) row) column))

(defun ans-cell-char (cell)
  "CP437 byte stored in CELL, or 32 when CELL is nil."
  (if cell (aref cell 0) 32))

(defun ans-cell-fg (cell)
  "Foreground of CELL: an index, or an (R G B) list."
  (if cell (aref cell 1) 7))

(defun ans-cell-bg (cell)
  "Background of CELL: an index, or an (R G B) list."
  (if cell (aref cell 2) 0))

(defun ans-cell-flags (cell)
  "Attribute bits of CELL.
Bit 0 is underline.  Bit 1 is italic.  Bit 2 is blink, stored only
when iCE colors are off."
  (if cell (aref cell 3) 0))

(defun ans-cell-underline-p (cell)
  "Non-nil when CELL is underlined."
  (not (zerop (logand (ans-cell-flags cell) 1))))

(defun ans-cell-italic-p (cell)
  "Non-nil when CELL is italic."
  (not (zerop (logand (ans-cell-flags cell) 2))))

(defun ans-cell-blink-p (cell)
  "Non-nil when CELL has the blink attribute.
iCE colors store a bright background instead of this bit."
  (not (zerop (logand (ans-cell-flags cell) 4))))

(defun ans-cell-default-p (cell)
  "Non-nil when CELL is a light-gray space on black."
  (and (= (ans-cell-char cell) 32)
       (equal (ans-cell-fg cell) 7)
       (equal (ans-cell-bg cell) 0)
       (= (ans-cell-flags cell) 0)))

(defun ans-make-cell (char fg bg &optional flags)
  "Return a cell for CP437 CHAR with FG, BG, and FLAGS."
  (vector (logand char 255) fg bg (or flags 0)))

(defun ans-grid-set-height (grid height)
  "Give GRID exactly HEIGHT rows, dropping rows past the end."
  (let ((rows (make-vector height nil)))
    (dotimes (i height)
      (aset rows i (aref (ans-grid-rows grid) i)))
    (setf (ans-grid-rows grid) rows)
    (setf (ans-grid-height grid) height)
    grid))

(defun ans-grid-set-cell (grid row column cell)
  "Store CELL at ROW and COLUMN of GRID.
ROW equal to the height adds one row of empty cells.  COLUMN must
already be inside the width.  Return CELL."
  (when (or (< row 0) (> row (ans-grid-height grid))
            (< column 0) (>= column (ans-grid-width grid)))
    (error "Cell %d,%d is outside the %d×%d screen"
           row column (ans-grid-width grid) (ans-grid-height grid)))
  (when (= row (ans-grid-height grid))
    (when (>= row ans-max-rows)
      (error "ANSI screen is limited to %d rows" ans-max-rows))
    (setf (ans-grid-rows grid)
          (vconcat (ans-grid-rows grid)
                   (vector (make-vector (ans-grid-width grid) nil))))
    (setf (ans-grid-height grid) (1+ row)))
  (aset (aref (ans-grid-rows grid) row) column cell)
  cell)

(defun ans-grid-set-width (grid width)
  "Resize GRID to WIDTH columns, keeping the left side of each row."
  (setq width (max 1 (min ans-max-columns width)))
  (let* ((height (ans-grid-height grid))
         (rows (make-vector height nil)))
    (dotimes (row height)
      (let ((line (make-vector width nil))
            (old (aref (ans-grid-rows grid) row)))
        (dotimes (column (min width (length old)))
          (aset line column (aref old column)))
        (aset rows row line)))
    (setf (ans-grid-width grid) width)
    (setf (ans-grid-rows grid) rows)
    grid))

(defun ans--raw-bytes (bytes)
  "Return BYTES as a string whose characters are the raw byte values."
  (cond
   ((not (stringp bytes))
    (error "ANSI data must be a string"))
   ((not (multibyte-string-p bytes))
    bytes)
   (t
    (encode-coding-string bytes 'raw-text-unix))))

(cl-defun ans-render-bytes (bytes &key width ice)
  "Render the ANSI artwork in BYTES to an `ans-grid'.
WIDTH forces the column count.  Otherwise a SAUCE character width is
used, then 80.  ICE is `on', `off', or omitted.  Omitted follows the
SAUCE iCE flag.

The grid's rows are vectors of cells.  Each cell is a vector
[CHAR FG BG FLAGS].  CHAR is a CP437 byte.  FG and BG are palette or
256-color indexes, or (R G B) lists."
  (let* ((bytes (ans--raw-bytes bytes))
         (sauce (ans-sauce-parse bytes))
         (limit (if sauce (ans-sauce-data-end sauce) (length bytes)))
         (width (max 1 (min ans-max-columns
                            (or (and width (> width 0) width)
                                (and sauce (ans-sauce-columns sauce))
                                80))))
         (ice (cond
               ((eq ice 'off) nil)
               ((memq ice '(on t)) t)
               (t (and sauce (ans-sauce-ice sauce)))))
         (row-cap (max 1 ans-max-rows))
         (row 0)
         (column 0)
         (max-row -1)
         (truncated nil)
         (rows (make-vector 32 nil))
         (fg 7)
         (bg 0)
         (fg-ext nil)
         (bg-ext nil)
         (bold nil)
         (blink nil)
         (inverse nil)
         (underline nil)
         (italic nil)
         (conceal nil)
         (saved-row 0)
         (saved-col 0))
    (cl-labels
        ((limit-row (value)
           (if (< value row-cap)
               value
             (setq truncated t)
             (1- row-cap)))
         (line (value)
           (while (>= value (length rows))
             (setq rows (vconcat rows (make-vector (max 32 (length rows)) nil))))
           (unless (aref rows value)
             (aset rows value (make-vector width nil)))
           (aref rows value))
         (reset-style ()
           (setq fg 7 bg 0 fg-ext nil bg-ext nil
                 bold nil blink nil inverse nil
                 underline nil italic nil conceal nil))
         (eff-fg ()
           (cond (fg-ext fg-ext)
                 ((and bold (<= fg 7)) (+ fg 8))
                 (t fg)))
         (eff-bg ()
           (cond (bg-ext bg-ext)
                 ((and blink ice (<= bg 7)) (+ bg 8))
                 (t bg)))
         (bake (char)
           (let ((fore (eff-fg))
                 (back (eff-bg))
                 (flags 0))
             (when inverse
               (let ((swap fore))
                 (setq fore back back swap)))
             (when conceal
               (setq fore back))
             (when underline
               (setq flags (logior flags 1)))
             (when italic
               (setq flags (logior flags 2)))
             ;; iCE uses blink as the bright-background bit.  The blink
             ;; attribute itself is kept only while iCE colors are off.
             (when (and blink (not ice))
               (setq flags (logior flags 4)))
             (vector char fore back flags)))
         (put (at-row at-col char)
           (when (and (>= at-row 0) (< at-row row-cap)
                      (>= at-col 0) (< at-col width))
             (aset (line at-row) at-col (bake char))
             (setq max-row (max max-row at-row))))
         (cancel-pending ()
           (when (>= column width)
             (setq column (1- width))))
         (emit (byte)
           (when (>= column width)
             (setq row (limit-row (1+ row))
                   column 0))
           (put row column byte)
           (setq column (1+ column)))
         (count (params)
           (let ((n (if params (car params) 1)))
             (if (<= n 0) 1 n)))
         (pos (n)
           (if (or (null n) (<= n 0)) 1 n))
         (cup (params)
           (setq row (limit-row (1- (pos (car params))))
                 column (1- (min (pos (cadr params)) width))))
         (clamp-byte (n)
           (max 0 (min 255 (or n 0))))
         (set-indexed (which value)
           (let ((color (clamp-byte value)))
             (if (= which 38)
                 (setq fg-ext color)
               (setq bg-ext color))))
         (set-rgb (which red green blue)
           (let ((color (list (clamp-byte red) (clamp-byte green) (clamp-byte blue))))
             (if (= which 38)
                 (setq fg-ext color)
               (setq bg-ext color))))
         (consume-color (which params index)
           (let ((n (length params)))
             (if (>= index n)
                 index
               (let ((mode (nth index params)))
                 (cond
                  ((and (= mode 5) (< (1+ index) n))
                   (set-indexed which (nth (1+ index) params))
                   (+ index 2))
                  ((and (= mode 2) (<= (+ index 4) n))
                   (set-rgb which
                            (nth (+ index 1) params)
                            (nth (+ index 2) params)
                            (nth (+ index 3) params))
                   (+ index 4))
                  (t (1+ index)))))))
         (sgr-one (value)
           (cond
            ((= value 0) (reset-style))
            ((= value 1) (setq bold t))
            ((= value 3) (setq italic t))
            ((= value 4) (setq underline t))
            ((= value 5) (setq blink t))
            ((= value 7) (setq inverse t))
            ((= value 8) (setq conceal t))
            ((= value 22) (setq bold nil))
            ((= value 23) (setq italic nil))
            ((= value 24) (setq underline nil))
            ((= value 25) (setq blink nil))
            ((= value 27) (setq inverse nil))
            ((= value 28) (setq conceal nil))
            ((and (<= 30 value 37)) (setq fg (- value 30) fg-ext nil))
            ((= value 39) (setq fg 7 fg-ext nil))
            ((and (<= 40 value 47)) (setq bg (- value 40) bg-ext nil))
            ((= value 49) (setq bg 0 bg-ext nil))
            ((and (<= 90 value 97)) (setq fg (+ 8 (- value 90)) fg-ext nil))
            ((and (<= 100 value 107)) (setq bg (+ 8 (- value 100)) bg-ext nil))))
         (apply-sgr (params)
           (let* ((items (or params (list 0)))
                  (index 0)
                  (n (length items)))
             (while (< index n)
               (let ((value (nth index items)))
                 (if (memq value '(38 48))
                     (setq index (consume-color value items (1+ index)))
                   (sgr-one value)
                   (setq index (1+ index)))))))
         (apply-pablo (params)
           (when (>= (length params) 4)
             (let ((color (list (clamp-byte (nth 1 params))
                                (clamp-byte (nth 2 params))
                                (clamp-byte (nth 3 params)))))
               (cond
                ((= (car params) 0) (setq bg-ext color))
                ((= (car params) 1) (setq fg-ext color))))))
         (clear-all ()
           (setq rows (make-vector 32 nil)
                 max-row -1))
         (erase-span (from-row from-col to-row to-col)
           (when (<= from-row to-row)
             (let ((r from-row))
               (while (<= r to-row)
                 (let ((c (if (= r from-row) from-col 0))
                       (end (if (= r to-row) to-col (1- width))))
                   (while (<= c end)
                     (put r c 32)
                     (setq c (1+ c))))
                 (setq r (1+ r))))))
         (erase-line (mode)
           (pcase mode
             (1 (erase-span row 0 row column))
             (2 (erase-span row 0 row (1- width)))
             (_ (erase-span row column row (1- width)))))
         (erase-display (mode)
           (pcase mode
             (2
              (clear-all)
              (setq row 0 column 0))
             (1
              (erase-span 0 0 row column))
             (_
              (erase-span row column row (1- width))
              (let ((below (1+ row)))
                (while (<= below max-row)
                  (when (< below (length rows))
                    (aset rows below nil))
                  (setq below (1+ below)))
                (when (>= max-row 0)
                  (setq max-row row))))))
         (dispatch (final params)
           (pcase final
             ((or ?H ?f) (cup params))
             (?A
              (setq row (max 0 (- row (count params))))
              (cancel-pending))
             (?B
              (setq row (limit-row (+ row (count params))))
              (cancel-pending))
             (?C
              (setq column (min width (+ column (count params)))))
             (?D
              (setq column (max 0 (- column (count params)))))
             (?G
              (setq column (1- (min (pos (car params)) width))))
             (?d
              (setq row (limit-row (1- (pos (car params)))))
              (cancel-pending))
             (?s
              (setq saved-row row saved-col column))
             (?u
              (setq row saved-row column saved-col))
             (?J (erase-display (if params (car params) 0)))
             (?K (erase-line (if params (car params) 0)))
             (?m (apply-sgr params))
             (?t (apply-pablo params))))
         (handle-csi (index)
           (let ((params nil)
                 (current nil)
                 (started nil)
                 (guard 0))
             (catch 'done
               (while (and (< index limit) (< guard 128))
                 (let ((byte (aref bytes index)))
                   (setq guard (1+ guard))
                   (cond
                    ((and (not started) (null params) (null current)
                          (memq byte '(?? ?= ?> ?<)))
                     (setq index (1+ index)))
                    ((<= ?0 byte ?9)
                     (setq started t
                           current (min 9999 (+ (* (or current 0) 10) (- byte ?0)))
                           index (1+ index)))
                    ((or (= byte ?\;) (= byte ?:))
                     (setq started t)
                     (push (or current 0) params)
                     (setq current nil
                           index (1+ index)))
                    ((<= #x20 byte #x2F)
                     (setq index (1+ index)))
                    ((<= ?@ byte ?~)
                     (when started
                       (push (or current 0) params))
                     (dispatch byte (nreverse params))
                     (throw 'done (1+ index)))
                    (t
                     (throw 'done index)))))
               index)))
         (tab ()
           (when (>= column width)
             (setq row (limit-row (1+ row))
                   column 0))
           (let ((next (+ column (- 8 (mod column 8)))))
             (setq column (if (>= next width) width next)))))
      (let ((index 0))
        (while (< index limit)
          (let ((byte (aref bytes index)))
            (cond
             ((= byte 26)
              (setq index limit))
             ((= byte 10)
              (setq row (limit-row (1+ row))
                    column 0
                    index (1+ index)))
             ((= byte 13)
              (setq column 0
                    index (1+ index)))
             ((= byte 9)
              (tab)
              (setq index (1+ index)))
             ((= byte 27)
              (setq index (1+ index))
              (when (< index limit)
                (if (= (aref bytes index) ?\[)
                    (setq index (handle-csi (1+ index)))
                  (pcase (aref bytes index)
                    (?7
                     (setq saved-row row saved-col column
                           index (1+ index)))
                    (?8
                     (setq row saved-row column saved-col
                           index (1+ index)))
                    (?c
                     (reset-style)
                     (clear-all)
                     (setq row 0 column 0
                           index (1+ index)))
                    (_ nil)))))
             (t
              (emit byte)
              (setq index (1+ index)))))))
      (if (< max-row 0)
          (ans-grid--make :width width :height 0 :ice ice :sauce sauce
                          :rows (vector) :truncated truncated)
        (let ((out (make-vector (1+ max-row) nil)))
          (dotimes (r (1+ max-row))
            (aset out r (or (and (< r (length rows)) (aref rows r))
                            (make-vector width nil))))
          (ans-grid--make :width width :height (1+ max-row) :ice ice
                          :sauce sauce :rows out :truncated truncated))))))

(defun ans--style-bytes (fg bg flags)
  "Return an SGR sequence that selects FG, BG, and FLAGS.
FLAGS bit 0 is underline.  Bit 1 is italic.  Bit 2 is blink.  The
sequence starts by resetting, so it does not depend on the previous
cell."
  (let ((parts (list 0))
        (underline (not (zerop (logand flags 1))))
        (italic (not (zerop (logand flags 2))))
        (blink (not (zerop (logand flags 4)))))
    (cond
     ((and (integerp fg) (<= 0 fg 7))
      (unless (= fg 7) (setq parts (append parts (list (+ 30 fg))))))
     ((and (integerp fg) (<= 8 fg 15))
      (setq parts (append parts (list (+ 90 (- fg 8))))))
     ((and (integerp fg) (<= 16 fg 255))
      (setq parts (append parts (list 38 5 fg))))
     ((consp fg)
      (setq parts (append parts (list 38 2 (nth 0 fg) (nth 1 fg) (nth 2 fg))))))
    (cond
     ((and (integerp bg) (<= 0 bg 7))
      (unless (= bg 0) (setq parts (append parts (list (+ 40 bg))))))
     ((and (integerp bg) (<= 8 bg 15))
      (setq parts (append parts (list (+ 100 (- bg 8))))))
     ((and (integerp bg) (<= 16 bg 255))
      (setq parts (append parts (list 48 5 bg))))
     ((consp bg)
      (setq parts (append parts (list 48 2 (nth 0 bg) (nth 1 bg) (nth 2 bg))))))
    (when underline (setq parts (append parts (list 4))))
    (when italic (setq parts (append parts (list 3))))
    (when blink (setq parts (append parts (list 5))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert 27 ?\[)
      (insert (mapconcat #'number-to-string parts ";"))
      (insert ?m)
      (buffer-string))))

(defun ans--glyph-byte (cell)
  "Return the CP437 byte to write for CELL.
Bytes in `ans-stream-controls' cannot round-trip through an ANSI
stream."
  (let ((byte (ans-cell-char cell)))
    (when (memq byte ans-stream-controls)
      (error "ANSI stream cannot store CP437 byte %d" byte))
    byte))

(defun ans--encode-artwork (grid)
  "Return the ANSI byte stream that draws GRID.
Each row ends in CR LF.  Trailing default cells are omitted.  The
column count is the grid width, so a short row does not wrap."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((style nil)
          (width (ans-grid-width grid)))
      (dotimes (row (ans-grid-height grid))
        (let* ((cells (aref (ans-grid-rows grid) row))
               (last (1- width)))
          (while (and (>= last 0)
                      (ans-cell-default-p (aref cells last)))
            (setq last (1- last)))
          ;; A blank row still writes one space, so the row survives a
          ;; later load.  A bare CR LF would leave no cell behind.
          (if (< last 0)
              (insert 32)
            (dotimes (column (1+ last))
              (let* ((cell (aref cells column))
                     (key (list (ans-cell-fg cell)
                                (ans-cell-bg cell)
                                (ans-cell-flags cell))))
                (unless (equal key style)
                  (insert (ans--style-bytes (car key) (cadr key) (caddr key)))
                  (setq style key))
                (insert (ans--glyph-byte cell))))))
        (insert 13 10)))
    (buffer-string)))

(defun ans--sauce-for-save (grid artwork-length)
  "Update GRID's SAUCE record for an artwork of ARTWORK-LENGTH bytes.
The saved file is ANSi.  Title, author, group, date, font, and
comments are kept.  Letter spacing and aspect stay in the flag.  The
iCE bit follows the grid.  Reserved flag bits, TInfo3, and TInfo4 are
zero.  FileSize is ARTWORK-LENGTH, which excludes the EOF byte and the
SAUCE record.  Return the struct."
  (let ((sauce (or (ans-grid-sauce grid)
                   (ans-sauce--make
                    :version "00" :title "" :author "" :group ""
                    :date (format-time-string "%Y-%m-%d")
                    :file-size 0 :data-type 1 :file-type 1
                    :tinfo1 0 :tinfo2 0 :tinfo3 0 :tinfo4 0
                    :comments nil
                    :flags (if (ans-grid-ice grid) 1 0)
                    :font "IBM VGA"
                    :data-end 0))))
    (setf (ans-sauce-version sauce) "00")
    (setf (ans-sauce-data-type sauce) 1)
    (setf (ans-sauce-file-type sauce) 1)
    (setf (ans-sauce-tinfo1 sauce) (ans-grid-width grid))
    (setf (ans-sauce-tinfo2 sauce) (ans-grid-height grid))
    ;; ANSi TInfo3 and TInfo4 are unused.  A compliant record stores 0.
    (setf (ans-sauce-tinfo3 sauce) 0)
    (setf (ans-sauce-tinfo4 sauce) 0)
    ;; Bits 1-4 are letter spacing and aspect.  Bits 5-7 are reserved.
    ;; Bit 0 is the grid's iCE flag.
    (setf (ans-sauce-flags sauce)
          (logior (logand (or (ans-sauce-flags sauce) 0) #x1E)
                  (if (ans-grid-ice grid) 1 0)))
    ;; FileSize is the original artwork.  The EOF byte, comment block,
    ;; and SAUCE record are appended after it.
    (setf (ans-sauce-file-size sauce) artwork-length)
    (unless (ans-sauce-font sauce)
      (setf (ans-sauce-font sauce) "IBM VGA"))
    (unless (ans-sauce-title sauce) (setf (ans-sauce-title sauce) ""))
    (unless (ans-sauce-author sauce) (setf (ans-sauce-author sauce) ""))
    (unless (ans-sauce-group sauce) (setf (ans-sauce-group sauce) ""))
    (unless (ans-sauce-date sauce)
      (setf (ans-sauce-date sauce) (format-time-string "%Y-%m-%d")))
    (setf (ans-grid-sauce grid) sauce)
    sauce))

(defun ans-encode-grid (grid)
  "Return ANSI bytes that draw GRID, followed by its SAUCE record.
The record describes this still screen.  An ANSiMation is saved as
ANSi of the canvas, which replaces the original stream."
  (let ((artwork (ans--encode-artwork grid)))
    (concat artwork (ans-sauce-encode (ans--sauce-for-save grid (length artwork))))))

(provide 'ans-render)
;;; ans-render.el ends here

;; Local Variables:
;; package-lint-main-file: "ans-mode.el"
;; End:

;; Local Variables:
;; package-lint-main-file: "ans-mode.el"
;; End:
