;;; ans-mode-tests.el --- Tests for ans-mode -*- lexical-binding: t -*-

(require 'ert)
(require 'ans-mode)

(defun ans-test-bytes (&rest parts)
  "Concatenate PARTS into a unibyte string.
A number is one byte.  A string is copied byte by byte."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (dolist (part parts)
      (cond
       ((integerp part) (insert part))
       ((stringp part)
        (dotimes (i (length part))
          (insert (aref part i))))
       (t (error "Bad part"))))
    (buffer-string)))

(defun ans-test-pad (text length)
  "Return TEXT padded with spaces to LENGTH bytes."
  (ans-test-bytes
   (with-temp-buffer
     (set-buffer-multibyte nil)
     (dotimes (i length)
       (insert (if (< i (length text)) (aref text i) 32)))
     (buffer-string))))

(defun ans-test-u16 (value)
  "Little-endian encoding of VALUE."
  (ans-test-bytes (logand value 255) (logand (ash value -8) 255)))

(defun ans-test-sauce (payload &rest spec)
  "Append a SAUCE record to PAYLOAD.
SPEC is a plist: :title :author :group :date :width :height :flags
:font :comments :file-type :data-type :eof."
  (let* ((comments (plist-get spec :comments))
         (date (replace-regexp-in-string "-" "" (or (plist-get spec :date) "")))
         (block nil))
    (when comments
      (setq block (ans-test-bytes "COMNT"))
      (dolist (comment comments)
        (setq block (concat block (ans-test-pad comment 64)))))
    (apply #'ans-test-bytes
           (delq nil
                 (list
                  payload
                  (and (plist-get spec :eof) 26)
                  block
                  "SAUCE" "00"
                  (ans-test-pad (or (plist-get spec :title) "") 35)
                  (ans-test-pad (or (plist-get spec :author) "") 20)
                  (ans-test-pad (or (plist-get spec :group) "") 20)
                  (ans-test-pad date 8)
                  0 0 0 0
                  (or (plist-get spec :data-type) 1)
                  (or (plist-get spec :file-type) 1)
                  (ans-test-u16 (or (plist-get spec :width) 0))
                  (ans-test-u16 (or (plist-get spec :height) 0))
                  0 0
                  0 0
                  (length comments)
                  (or (plist-get spec :flags) 0)
                  (ans-test-pad (or (plist-get spec :font) "") 22))))))

(defun ans-test-ppm-header (ppm)
  "Return (WIDTH . HEIGHT) from PPM, leaving the match at the pixel data."
  (string-match "\\`P6\n\\([0-9]+\\) \\([0-9]+\\)\n255\n" ppm)
  (cons (string-to-number (match-string 1 ppm))
        (string-to-number (match-string 2 ppm))))

(defun ans-test-ppm-pixel (ppm x y)
  "Return (R G B) of pixel X Y in PPM."
  (let* ((size (ans-test-ppm-header ppm))
         (index (+ (match-end 0) (* (+ (* y (car size)) x) 3))))
    (list (aref ppm index) (aref ppm (1+ index)) (aref ppm (+ index 2)))))

(ert-deftest ans-cp437-graphics ()
  (should (= (ans-cp437-char #x01) #x263A))
  (should (= (ans-cp437-char #x07) #x2022))
  (should (= (ans-cp437-char #xDB) #x2588))
  (should (= (ans-cp437-char #xB0) #x2591))
  (should (= (ans-cp437-char #xC4) #x2500))
  (should (= (ans-cp437-char #x7F) #x2302))
  (should (= (ans-cp437-char #x00) #x20))
  (should (= (ans-vga-byte (ans-vga-font 16) #xDB 0) #xFF))
  (should (= (ans-vga-byte (ans-vga-font 8) #xDB 0) #xFF)))

(ert-deftest ans-sauce-parse-basic ()
  (let* ((bytes (ans-test-sauce
                 (ans-test-bytes "Hi")
                 :title "Winter" :author "Ada" :group "ACiD"
                 :date "1996-04-01" :width 40 :height 12
                 :flags 1 :font "IBM VGA" :eof t))
         (sauce (ans-sauce-parse bytes)))
    (should sauce)
    (should (equal (ans-sauce-title sauce) "Winter"))
    (should (equal (ans-sauce-author sauce) "Ada"))
    (should (equal (ans-sauce-group sauce) "ACiD"))
    (should (equal (ans-sauce-date sauce) "1996-04-01"))
    (should (equal (ans-sauce-font sauce) "IBM VGA"))
    (should (= (ans-sauce-columns sauce) 40))
    (should (= (ans-sauce-declared-rows sauce) 12))
    (should (ans-sauce-ice sauce))
    (should (eq (ans-sauce-spacing sauce) nil))
    (should (= (ans-sauce-data-end sauce) 2))))

(ert-deftest ans-sauce-trailing-junk-keeps-font-padding ()
  (let* ((padded (ans-test-sauce (ans-test-bytes "Q")
                                 :title "Pad" :font "IBM VGA"
                                 :width 40 :eof t))
         (sauce (ans-sauce-parse (ans-test-bytes padded 0 0 10))))
    (should (equal (ans-sauce-title sauce) "Pad"))
    (should (equal (ans-sauce-font sauce) "IBM VGA"))
    (should (= (ans-sauce-columns sauce) 40))
    (should (= (ans-sauce-data-end sauce) 1))))

(ert-deftest ans-sauce-comments-without-eof ()
  (let* ((bytes (ans-test-sauce
                 (ans-test-bytes "Z")
                 :title "T" :comments '("Hello" "There")
                 :width 80 :flags (ash 2 1) :font "IBM VGA50"))
         (sauce (ans-sauce-parse bytes)))
    (should (equal (ans-sauce-comments sauce) '("Hello" "There")))
    (should (eq (ans-sauce-spacing sauce) 9))
    (should (= (ans-sauce-data-end sauce) 1))
    (let ((grid (ans-render-bytes bytes)))
      (should (= (ans-grid-height grid) 1))
      (should (= (ans-cell-char (ans-grid-cell grid 0 0)) ?Z))
      (should (= (ans-grid-width grid) 80)))))

(ert-deftest ans-sauce-absent ()
  (should-not (ans-sauce-parse (ans-test-bytes "Hello"))))

(ert-deftest ans-render-colors-and-cursor ()
  (let ((grid (ans-render-bytes
               (ans-test-bytes "AB" #x1b "[1;1HC" #x1b "[31mD"))))
    (should (= (ans-cell-char (ans-grid-cell grid 0 0)) ?C))
    (should (= (ans-cell-char (ans-grid-cell grid 0 1)) ?D))
    (should (= (ans-cell-fg (ans-grid-cell grid 0 1)) 1))
    (should (= (ans-cell-fg (ans-grid-cell grid 0 0)) 7))))

(ert-deftest ans-render-bold-and-reset ()
  (let ((grid (ans-render-bytes
               (ans-test-bytes #x1b "[1;31mA" #x1b "[0mB" #x1b "[31;1mC"
                               #x1b "[31;mD"))))
    (should (= (ans-cell-fg (ans-grid-cell grid 0 0)) 9))
    (should (= (ans-cell-fg (ans-grid-cell grid 0 1)) 7))
    (should (= (ans-cell-fg (ans-grid-cell grid 0 2)) 9))
    (should (= (ans-cell-fg (ans-grid-cell grid 0 3)) 7))))

(ert-deftest ans-render-pending-wrap ()
  (let* ((full (ans-render-bytes
                (ans-test-bytes (make-string 80 ?A) "\r\nB")))
         (spill (ans-render-bytes
                 (ans-test-bytes (make-string 80 ?A) "B")))
         (cr (ans-render-bytes
              (ans-test-bytes (make-string 80 ?A) "\rB"))))
    (should (= (ans-grid-height full) 2))
    (should (= (ans-cell-char (ans-grid-cell full 0 79)) ?A))
    (should (= (ans-cell-char (ans-grid-cell full 1 0)) ?B))
    (should (= (ans-grid-height spill) 2))
    (should (= (ans-cell-char (ans-grid-cell spill 1 0)) ?B))
    (should (= (ans-cell-char (ans-grid-cell cr 0 0)) ?B))
    (should (= (ans-cell-char (ans-grid-cell cr 0 79)) ?A))
    (should (= (ans-grid-height cr) 1))))

(ert-deftest ans-render-cr-lf-and-tab ()
  (let ((grid (ans-render-bytes (ans-test-bytes "AB\rC\nD\tE"))))
    (should (= (ans-cell-char (ans-grid-cell grid 0 0)) ?C))
    (should (= (ans-cell-char (ans-grid-cell grid 0 1)) ?B))
    (should (= (ans-cell-char (ans-grid-cell grid 1 0)) ?D))
    (should (= (ans-cell-char (ans-grid-cell grid 1 8)) ?E))))

(ert-deftest ans-render-ice ()
  (let* ((seq (ans-test-bytes #x1b "[31;45;5mX"))
         (on (ans-render-bytes seq :ice 'on))
         (off (ans-render-bytes seq :ice 'off)))
    (should (= (ans-cell-fg (ans-grid-cell on 0 0)) 1))
    (should (= (ans-cell-bg (ans-grid-cell on 0 0)) 13))
    (should (= (ans-cell-bg (ans-grid-cell off 0 0)) 5))
    (should (ans-grid-ice on))
    (should-not (ans-grid-ice off))))

(ert-deftest ans-render-truecolor-and-256 ()
  (let ((grid (ans-render-bytes
               (ans-test-bytes
                #x1b "[38;2;1;2;3mA"
                #x1b "[48;5;196mB"
                #x1b "[1;10;20;30tC"))))
    (should (equal (ans-cell-fg (ans-grid-cell grid 0 0)) '(1 2 3)))
    (should (= (ans-cell-bg (ans-grid-cell grid 0 1)) 196))
    (should (equal (ans-cell-fg (ans-grid-cell grid 0 2)) '(10 20 30)))))

(ert-deftest ans-render-erase-and-save-cursor ()
  (let ((erased (ans-render-bytes
                 (ans-test-bytes "HELLO" #x1b "[2JOK")))
        (line (ans-render-bytes
               (ans-test-bytes "ABCD" #x1b "[2D" #x1b "[K")))
        (saved (ans-render-bytes
                (ans-test-bytes "A" #x1b "[sB" #x1b "[uC"))))
    (should (= (ans-grid-height erased) 1))
    (should (= (ans-cell-char (ans-grid-cell erased 0 0)) ?O))
    (should (= (ans-cell-char (ans-grid-cell erased 0 1)) ?K))
    (should (= (ans-cell-char (ans-grid-cell line 0 0)) ?A))
    (should (= (ans-cell-char (ans-grid-cell line 0 1)) ?B))
    (should (= (ans-cell-char (ans-grid-cell line 0 2)) 32))
    (should (= (ans-cell-char (ans-grid-cell saved 0 0)) ?A))
    (should (= (ans-cell-char (ans-grid-cell saved 0 1)) ?C))))

(ert-deftest ans-render-stops-before-sauce ()
  (let* ((bytes (ans-test-sauce (ans-test-bytes "Hi")
                                :title "Title" :width 40 :eof t))
         (grid (ans-render-bytes bytes)))
    (should (= (ans-grid-width grid) 40))
    (should (= (ans-grid-height grid) 1))
    (should (= (ans-cell-char (ans-grid-cell grid 0 0)) ?H))
    (should (= (ans-cell-char (ans-grid-cell grid 0 1)) ?i))
    (should (= (ans-cell-char (ans-grid-cell grid 0 2)) 32))))

(ert-deftest ans-render-sub-stops ()
  (let ((grid (ans-render-bytes (ans-test-bytes "A" 26 "B"))))
    (should (= (ans-grid-height grid) 1))
    (should (= (ans-cell-char (ans-grid-cell grid 0 0)) ?A))
    (should (= (ans-cell-char (ans-grid-cell grid 0 1)) 32))))

(ert-deftest ans-render-sauce-width-wraps ()
  (let ((grid (ans-render-bytes
               (ans-test-sauce (ans-test-bytes (make-string 50 ?A))
                               :width 40 :eof t))))
    (should (= (ans-grid-width grid) 40))
    (should (= (ans-grid-height grid) 2))
    (should (= (ans-cell-char (ans-grid-cell grid 1 9)) ?A))
    (should (= (ans-cell-char (ans-grid-cell grid 1 10)) 32))))

(ert-deftest ans-ppm-block-nine-pixel-and-vga50 ()
  (let* ((block (ans-render-bytes (ans-test-bytes #x1b "[31m" #xDB) :width 1))
         (ppm (ans-render-ppm block 8 (ans-vga-font 16)))
         (size (ans-test-ppm-header ppm))
         (box (ans-render-bytes (ans-test-bytes #xC4) :width 1))
         (wide (ans-render-ppm box 9 (ans-vga-font 16)))
         (letter (ans-render-ppm
                  (ans-render-bytes (ans-test-bytes "A") :width 1)
                  9 (ans-vga-font 16)))
         (fifty (ans-render-ppm
                 (ans-render-bytes
                  (ans-test-sauce (ans-test-bytes "A")
                                  :font "IBM VGA50" :width 80 :eof t)))))
    (should (equal size '(8 . 16)))
    (should (equal (ans-test-ppm-pixel ppm 0 0) '(170 0 0)))
    (should (equal (ans-test-ppm-pixel ppm 7 15) '(170 0 0)))
    (should (= (car (ans-test-ppm-header wide)) 9))
    (let ((ninth-matches nil)
          (y 0))
      (while (< y 16)
        (let ((eighth (ans-test-ppm-pixel wide 7 y))
              (ninth (ans-test-ppm-pixel wide 8 y)))
          (when (equal eighth '(170 170 170))
            (setq ninth-matches (equal ninth eighth))))
        (setq y (1+ y)))
      (should ninth-matches))
    (let ((y 0)
          (bg t))
      (while (< y 16)
        (unless (equal (ans-test-ppm-pixel letter 8 y) '(0 0 0))
          (setq bg nil))
        (setq y (1+ y)))
      (should bg))
    (should (= (cdr (ans-test-ppm-header fifty)) 8))))

(ert-deftest ans-text-view-and-save-roundtrip ()
  (let* ((dir (make-temp-file "ans-mode" t))
         (file (expand-file-name "piece.ans" dir))
         (bytes (ans-test-sauce
                 (ans-test-bytes #x1b "[31mA" #xDB "\r\n")
                 :title "Round" :author "Ada" :eof t))
         (ans-view 'text))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil file nil 'silent))
          (find-file file)
          (should (eq major-mode 'ans-mode))
          (should (eq ans--view 'text))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) ?A))
          (should (= (ans-cell-fg (ans-grid-cell ans--grid 0 0)) 1))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 1)) #xDB))
          (let ((face (get-text-property (point-min) 'face)))
            (should (equal (plist-get face :foreground) "#AA0000"))
            (should (equal (plist-get face :background) "#000000")))
          (should (string-match-p "Round" (ans--header-line)))
          (should-not (string-match-p "SAUCE" (buffer-string)))
          (set-buffer-modified-p t)
          (save-buffer)
          (let ((saved (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally file)
                         (buffer-string))))
            (should (equal saved bytes)))
          (kill-buffer))
      (delete-directory dir t))))

(ert-deftest ans-image-view-inserts-raster ()
  (let* ((dir (make-temp-file "ans-mode" t))
         (file (expand-file-name "raster.ans" dir))
         (bytes (ans-test-bytes #x1b "[32mHi\r\n"))
         (ans-view 'image))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil file nil 'silent))
          (find-file file)
          (should (eq ans--view 'image))
          (should (eq (car-safe (get-text-property (point-min) 'display)) 'image))
          (kill-buffer))
      (delete-directory dir t))))

(defun ans-test-cells-equal (a b)
  "Non-nil when cells A and B show the same glyph, colors, and flags."
  (and (= (ans-cell-char a) (ans-cell-char b))
       (equal (ans-cell-fg a) (ans-cell-fg b))
       (equal (ans-cell-bg a) (ans-cell-bg b))
       (= (ans-cell-flags a) (ans-cell-flags b))))

(defun ans-test-grids-equal (a b)
  "Non-nil when grids A and B have the same cells."
  (and (= (ans-grid-width a) (ans-grid-width b))
       (= (ans-grid-height a) (ans-grid-height b))
       (catch 'diff
         (dotimes (row (ans-grid-height a))
           (dotimes (column (ans-grid-width a))
             (unless (ans-test-cells-equal (ans-grid-cell a row column)
                                           (ans-grid-cell b row column))
               (throw 'diff nil))))
         t)))

(ert-deftest ans-cp437-byte-roundtrip ()
  (should (= (ans-cp437-byte ?A) ?A))
  (should (= (ans-cp437-byte ?\s) 32))
  (should (= (ans-cp437-byte (ans-cp437-char #x01)) #x01))
  (should (= (ans-cp437-byte (ans-cp437-char #xDB)) #xDB))
  (should (= (ans-cp437-byte (ans-cp437-char 127)) 127))
  (should-not (ans-cp437-byte ?λ)))

(ert-deftest ans-encode-grid-roundtrip ()
  (let* ((source (ans-test-sauce
                  (ans-test-bytes
                   #x1b "[31;44mHi" #x1b "[1;4m!" #x1b "[0m"
                   "\r\n" #x1b "[92;106m" #xDB "\r\n")
                  :title "Round" :author "Ada" :group "Group"
                  :font "IBM VGA" :width 40 :flags 1 :eof t
                  :comments '("a note")))
         (grid (ans-render-bytes source))
         (again (ans-render-bytes (ans-encode-grid grid)))
         (sauce (ans-grid-sauce again)))
    (should (ans-test-grids-equal grid again))
    (should (equal (ans-sauce-title sauce) "Round"))
    (should (equal (ans-sauce-author sauce) "Ada"))
    (should (equal (ans-sauce-group sauce) "Group"))
    (should (equal (ans-sauce-comments sauce) '("a note")))
    (should (equal (ans-sauce-font sauce) "IBM VGA"))
    (should (= (ans-sauce-columns sauce) 40))
    (should (= (ans-sauce-declared-rows sauce) (ans-grid-height grid)))
    (should (ans-sauce-ice sauce))
    (should (= (ans-sauce-file-type sauce) 1))))

(ert-deftest ans-encode-blank-row-and-rgb ()
  (let* ((grid (ans-render-bytes
                (ans-test-bytes "A" "\r\n" "\r\n" #x1b "[38;2;1;2;3;48;5;196mB")))
         (again (ans-render-bytes (ans-encode-grid grid))))
    (should (= (ans-grid-height again) 3))
    (should (ans-test-cells-equal (ans-grid-cell grid 2 0)
                                  (ans-grid-cell again 2 0)))))

(ert-deftest ans-edit-save-replaces-cell ()
  (let* ((dir (make-temp-file "ans-edit" t))
         (file (expand-file-name "edit.ans" dir))
         (bytes (ans-test-sauce
                 (ans-test-bytes #x1b "[31mAB" "\r\n")
                 :title "Edit" :author "Ada" :width 20 :eof t))
         (ans-view 'text))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil file nil 'silent))
          (find-file file)
          (ans-edit-mode 1)
          (setq ans--pen-fg 2 ans--pen-bg 4)
          (setq last-command-event ?Z)
          (call-interactively #'ans-insert-char)
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) ?Z))
          (should (= (ans-cell-fg (ans-grid-cell ans--grid 0 0)) 2))
          (should (= (ans-cell-bg (ans-grid-cell ans--grid 0 0)) 4))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 1)) ?B))
          (should ans--edited)
          (save-buffer)
          (should-not ans--edited)
          (kill-buffer)
          (find-file file)
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) ?Z))
          (should (= (ans-cell-fg (ans-grid-cell ans--grid 0 0)) 2))
          (should (= (ans-cell-bg (ans-grid-cell ans--grid 0 0)) 4))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 1)) ?B))
          (should (equal (ans-sauce-title (ans-grid-sauce ans--grid)) "Edit"))
          (should (equal (ans-sauce-author (ans-grid-sauce ans--grid)) "Ada"))
          (ans-edit-mode 1)
          (let ((undo-cell (ans-cell-char (ans-grid-cell ans--grid 0 0))))
            (setq last-command-event ?Q)
            (call-interactively #'ans-insert-char)
            (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) ?Q))
            (execute-kbd-macro (kbd "C-/"))
            (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) undo-cell))
            (should-not ans--edited)
            (execute-kbd-macro (kbd "C-?"))
            (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) ?Q))
            (should ans--edited)
            (execute-kbd-macro (kbd "C-/"))
            (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) undo-cell))
            (should-not ans--edited))
          (kill-buffer))
      (delete-directory dir t))))

(ert-deftest ans-edit-undo-restores-original-bytes ()
  (let* ((dir (make-temp-file "ans-undo" t))
         (file (expand-file-name "undo.ans" dir))
         (bytes (ans-test-sauce
                 (ans-test-bytes #x1b "[31mAB" "\r\n")
                 :title "Edit" :author "Ada" :width 20 :eof t))
         (ans-view 'text))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil file nil 'silent))
          (find-file file)
          (ans-edit-mode 1)
          (setq ans--pen-fg 2 ans--pen-bg 4)
          (execute-kbd-macro (kbd "ZY"))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) ?Z))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 1)) ?Y))
          (execute-kbd-macro (kbd "C-/ C-/"))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) ?A))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 1)) ?B))
          (should-not ans--edited)
          (save-buffer)
          (let ((saved (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally file)
                         (buffer-string))))
            (should (equal saved bytes)))
          (execute-kbd-macro (kbd "C-? C-?"))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 0)) ?Z))
          (should (= (ans-cell-fg (ans-grid-cell ans--grid 0 0)) 2))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 0 1)) ?Y))
          (execute-kbd-macro (kbd "C-e RET Q"))
          (should (= (ans-grid-height ans--grid) 2))
          (should (= (ans-cell-char (ans-grid-cell ans--grid 1 0)) ?Q))
          (execute-kbd-macro (kbd "C-/ C-/"))
          (should (= (ans-grid-height ans--grid) 1))
          (kill-buffer))
      (delete-directory dir t))))

(provide 'ans-mode-tests)
;;; ans-mode-tests.el ends here
