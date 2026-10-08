;;; ans-sauce.el --- SAUCE records and CP437 text for ans-mode -*- lexical-binding: t -*-

;; Copyright (C) 2026 William Theesfeld <william@theesfeld.net>

;; Author: William Theesfeld <william@theesfeld.net>
;; Keywords: multimedia

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Parser for SAUCE v00 (Standard Architecture for Universal Comment
;; Extensions) and the CP437 mapping used to display those strings.
;;
;; A SAUCE record is the last 128 bytes of the file, optionally
;; preceded by a COMNT block.  Character fields are CP437 and padded
;; with spaces.  TInfoS, the font name, is a NUL-terminated string
;; padded with binary zeros.  Character files store the column count
;; in TInfo1 and a row hint in TInfo2.  Flag bit 0 selects iCE colors
;; (bright backgrounds instead of blink).  Bits 1-2 select 8- or
;; 9-pixel letter spacing.  Bits 3-4 select the aspect ratio.  Bits
;; 5-7 are reserved.

;;; Code:

(require 'cl-lib)

(defgroup ans nil
  "View and edit ANSI art and SAUCE metadata."
  :group 'multimedia
  :prefix "ans-")

(defconst ans-cp437-table
  (let ((inhibit-eol-conversion t)
        (table (make-vector 256 32)))
    (dotimes (i 256)
      (let ((decoded (decode-coding-string (unibyte-string i) 'cp437-unix)))
        (when (= (length decoded) 1)
          (aset table i (aref decoded 0)))))
    ;; Emacs maps bytes 0-31 and 127 to controls.  In ANSI art those
    ;; bytes are the classic CP437 glyphs.
    (dolist (pair '((0 . #x20)
                    (1 . #x263A) (2 . #x263B) (3 . #x2665) (4 . #x2666)
                    (5 . #x2663) (6 . #x2660) (7 . #x2022) (8 . #x25D8)
                    (9 . #x25CB) (10 . #x25D9) (11 . #x2642) (12 . #x2640)
                    (13 . #x266A) (14 . #x266B) (15 . #x263C) (16 . #x25BA)
                    (17 . #x25C4) (18 . #x2195) (19 . #x203C) (20 . #x00B6)
                    (21 . #x00A7) (22 . #x25AC) (23 . #x21A8) (24 . #x2191)
                    (25 . #x2193) (26 . #x2192) (27 . #x2190) (28 . #x221F)
                    (29 . #x2194) (30 . #x25B2) (31 . #x25BC) (127 . #x2302)))
      (aset table (car pair) (cdr pair)))
    table)
  "Map a CP437 byte to a Unicode character.
Byte 0 is a space.  Bytes 1-31 and 127 are the graphic glyphs.")

(defconst ans-sauce--data-type-names
  ["None" "Character" "Bitmap" "Vector" "Audio" "BinaryText" "XBin"
   "Archive" "Executable"]
  "Names for the SAUCE DataType byte.")

(defconst ans-sauce--char-type-names
  ["ASCII" "ANSi" "ANSiMation" "RIP script" "PCBoard" "Avatar" "HTML"
   "Source" "TundraDraw"]
  "Names for Character FileType values.")

(cl-defstruct (ans-sauce (:constructor ans-sauce--make) (:copier nil))
  "One parsed SAUCE record."
  version title author group date file-size
  data-type file-type
  tinfo1 tinfo2 tinfo3 tinfo4
  comments flags font data-end)

(defun ans-cp437-char (byte)
  "Return the Unicode character for CP437 BYTE."
  (aref ans-cp437-table (logand byte 255)))

(defconst ans-cp437-reverse
  (let ((map (make-hash-table :test #'eq)))
    (dotimes (byte 256)
      (let ((char (aref ans-cp437-table byte)))
        ;; Space is both byte 0 and byte 32.  Prefer the printable byte.
        (when (or (null (gethash char map)) (>= byte 32))
          (puthash char byte map))))
    map)
  "Map a Unicode character back to a CP437 byte.")

(defun ans-cp437-byte (char)
  "Return the CP437 byte for CHAR, or nil when CHAR has no glyph."
  (and (characterp char) (gethash char ans-cp437-reverse)))

(defconst ans-stream-controls '(9 10 13 26 27)
  "CP437 bytes that an ANSI stream treats as controls.
Tab, line feed, carriage return, SUB, and escape cannot be stored as
glyphs.  The other bytes below 32 are the classic control pictures.")

(defun ans--u16 (bytes index)
  "Read a little-endian unsigned 16-bit value from BYTES at INDEX."
  (+ (aref bytes index)
     (* 256 (aref bytes (1+ index)))))

(defun ans--u32 (bytes index)
  "Read a little-endian unsigned 32-bit value from BYTES at INDEX."
  (+ (aref bytes index)
     (* 256 (aref bytes (+ index 1)))
     (* 65536 (aref bytes (+ index 2)))
     (* 16777216 (aref bytes (+ index 3)))))

(defun ans--bytes-match (bytes start string)
  "Return non-nil if BYTES at START begins with STRING."
  (let ((length (length string))
        (ok (and (>= start 0) (<= (+ start (length string)) (length bytes)))))
    (when ok
      (dotimes (i length)
        (unless (= (aref bytes (+ start i)) (aref string i))
          (setq ok nil))))
    ok))

(defun ans--sauce-text (bytes start length)
  "Decode LENGTH CP437 bytes at START, trimmed as a SAUCE field.
Decoding stops at the first NUL.  Trailing spaces are removed."
  (let ((index start)
        (end (+ start length))
        (last start))
    (while (and (< index end) (/= (aref bytes index) 0))
      (unless (= (aref bytes index) 32)
        (setq last (1+ index)))
      (setq index (1+ index)))
    (with-temp-buffer
      (set-buffer-multibyte t)
      (dotimes (k (- last start))
        (insert (ans-cp437-char (aref bytes (+ start k)))))
      (buffer-string))))

(defun ans--sauce-date (bytes start)
  "Decode the 8-byte SAUCE date at START as YYYY-MM-DD when numeric."
  (let ((text (ans--sauce-text bytes start 8)))
    (if (string-match "\\`\\([0-9]\\{4\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\'" text)
        (format "%s-%s-%s"
                (match-string 1 text)
                (match-string 2 text)
                (match-string 3 text))
      text)))

(defun ans--sauce-origin (bytes)
  "Return the index of a trailing SAUCE record in BYTES, or nil.
The record is the 128 bytes ending at the file, or ending just before
up to 16 trailing spaces, NULs, or line breaks.  Each alignment is
checked before another padding byte is skipped, so spaces that pad the
font name stay part of the record."
  (let ((end (length bytes))
        (found nil))
    (dotimes (skipped 17)
      (unless found
        (when (and (>= end 128)
                   (ans--bytes-match bytes (- end 128) "SAUCE")
                   (ans--bytes-match bytes (- end 123) "00"))
          (setq found (- end 128)))
        (if (and (not found)
                 (< skipped 16)
                 (> end 0)
                 (memq (aref bytes (1- end)) '(0 9 10 13 32)))
            (setq end (1- end))
          (unless found
            (setq found 'none)))))
    (and (integerp found) found)))

(defun ans-sauce-parse (bytes)
  "Parse a SAUCE record from unibyte string BYTES.
Return an `ans-sauce' struct, or nil when the file has no record.
`ans-sauce-data-end' is the index where the artwork bytes stop,
before a preceding EOF byte, COMNT block, and the record itself."
  (let ((origin (ans--sauce-origin bytes)))
    (when origin
      (let* ((count (aref bytes (+ origin 104)))
             (data-end origin)
             (comments nil))
        (when (> count 0)
          (let* ((block (+ 5 (* count 64)))
                 (start (- origin block)))
            (when (and (>= start 0)
                       (ans--bytes-match bytes start "COMNT"))
              (setq data-end start)
              (dotimes (n count)
                (push (ans--sauce-text bytes (+ start 5 (* n 64)) 64)
                      comments))
              (setq comments (nreverse comments)))))
        (when (and (> data-end 0)
                   (= (aref bytes (1- data-end)) 26))
          (setq data-end (1- data-end)))
        (ans-sauce--make
         :version "00"
         :title (ans--sauce-text bytes (+ origin 7) 35)
         :author (ans--sauce-text bytes (+ origin 42) 20)
         :group (ans--sauce-text bytes (+ origin 62) 20)
         :date (ans--sauce-date bytes (+ origin 82))
         :file-size (ans--u32 bytes (+ origin 90))
         :data-type (aref bytes (+ origin 94))
         :file-type (aref bytes (+ origin 95))
         :tinfo1 (ans--u16 bytes (+ origin 96))
         :tinfo2 (ans--u16 bytes (+ origin 98))
         :tinfo3 (ans--u16 bytes (+ origin 100))
         :tinfo4 (ans--u16 bytes (+ origin 102))
         :comments comments
         :flags (aref bytes (+ origin 105))
         :font (ans--sauce-text bytes (+ origin 106) 22)
         :data-end data-end)))))

(defun ans-sauce-columns (sauce)
  "Column count stored for a character file, or nil.
ASCII, ANSi, and ANSiMation store that count in TInfo1.  Zero means
the file did not record a width."
  (when (and (= (ans-sauce-data-type sauce) 1)
             (<= (ans-sauce-file-type sauce) 2))
    (let ((width (ans-sauce-tinfo1 sauce)))
      (and (> width 0) (<= width 4096) width))))

(defun ans-sauce-declared-rows (sauce)
  "Row hint stored for a character file, or nil.
For ANSiMation this is the screen height, not the rendered length."
  (when (and (= (ans-sauce-data-type sauce) 1)
             (<= (ans-sauce-file-type sauce) 2))
    (let ((rows (ans-sauce-tinfo2 sauce)))
      (and (> rows 0) rows))))

(defun ans-sauce-ice (sauce)
  "Non-nil when SAUCE requests iCE colors (non-blink mode)."
  (not (zerop (logand (ans-sauce-flags sauce) 1))))

(defun ans-sauce-spacing (sauce)
  "Return 8, 9, or nil for the SAUCE letter-spacing flag.
Nil means the legacy value, which does not request either width."
  (pcase (logand (ash (ans-sauce-flags sauce) -1) 3)
    (1 8)
    (2 9)
    (_ nil)))

(defun ans-sauce-aspect (sauce)
  "Return a short name for the SAUCE aspect-ratio flag."
  (pcase (logand (ash (ans-sauce-flags sauce) -3) 3)
    (0 "legacy")
    (1 "legacy device")
    (2 "square pixels")
    (_ "invalid")))

(defun ans-sauce-type-label (sauce)
  "Return a \"DataType / FileType\" label for SAUCE."
  (let* ((data (ans-sauce-data-type sauce))
         (file (ans-sauce-file-type sauce))
         (data-name (if (< data (length ans-sauce--data-type-names))
                        (aref ans-sauce--data-type-names data)
                      (format "DataType %d" data)))
         (file-name (if (and (= data 1)
                             (< file (length ans-sauce--char-type-names)))
                        (aref ans-sauce--char-type-names file)
                      (format "FileType %d" file))))
    (format "%s / %s" data-name file-name)))

(defun ans--field (text length)
  "Return LENGTH CP437 bytes for TEXT, padded with spaces.
A character with no CP437 glyph is stored as `?'."
  (setq text (or text ""))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (dotimes (i length)
      (insert (if (< i (length text))
                  (or (ans-cp437-byte (aref text i)) ??)
                32)))
    (buffer-string)))

(defun ans--zfield (text length)
  "Return LENGTH bytes for the SAUCE ZString TEXT.
CP437 bytes are followed by a NUL and binary zeros.  A value that
fills LENGTH is stored without a terminating NUL.  A character with
no CP437 glyph is stored as `?'."
  (setq text (or text ""))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((n (min (length text) length)))
      (dotimes (i n)
        (insert (or (ans-cp437-byte (aref text i)) ??)))
      (dotimes (_ (- length n))
        (insert 0)))
    (buffer-string)))

(defun ans--date-field (date)
  "Return the 8-byte SAUCE date for DATE.
DATE is YYYY-MM-DD, 8 raw characters, or nil."
  (ans--field
   (if (and date
            (string-match
             "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\'"
             date))
       (concat (match-string 1 date)
               (match-string 2 date)
               (match-string 3 date))
     date)
   8))

(defun ans--u16-bytes (value)
  "Return the little-endian encoding of the 16-bit integer VALUE."
  (unibyte-string (logand value 255) (logand (ash value -8) 255)))

(defun ans--u32-bytes (value)
  "Return the little-endian encoding of the 32-bit integer VALUE."
  (unibyte-string (logand value 255)
                  (logand (ash value -8) 255)
                  (logand (ash value -16) 255)
                  (logand (ash value -24) 255)))

(defun ans-sauce-encode (sauce)
  "Return the SAUCE trailer for SAUCE.
The trailer is one EOF byte, the comment block, and the 128-byte
record.  SAUCE is an `ans-sauce' struct.  Its file size, column count,
row count, flags, and file type are stored as they stand."
  (let* ((comments (ans-sauce-comments sauce))
         (count (length comments)))
    (when (> count 255)
      (error "SAUCE holds at most 255 comments"))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert 26)
      (when (> count 0)
        (insert "COMNT")
        (dolist (comment comments)
          (insert (ans--field comment 64))))
      (insert "SAUCE" "00"
              (ans--field (ans-sauce-title sauce) 35)
              (ans--field (ans-sauce-author sauce) 20)
              (ans--field (ans-sauce-group sauce) 20)
              (ans--date-field (ans-sauce-date sauce))
              (ans--u32-bytes (or (ans-sauce-file-size sauce) 0))
              (or (ans-sauce-data-type sauce) 1)
              (or (ans-sauce-file-type sauce) 1)
              (ans--u16-bytes (or (ans-sauce-tinfo1 sauce) 0))
              (ans--u16-bytes (or (ans-sauce-tinfo2 sauce) 0))
              (ans--u16-bytes (or (ans-sauce-tinfo3 sauce) 0))
              (ans--u16-bytes (or (ans-sauce-tinfo4 sauce) 0))
              count
              (or (ans-sauce-flags sauce) 0)
              (ans--zfield (ans-sauce-font sauce) 22))
      (buffer-string))))

(provide 'ans-sauce)
;;; ans-sauce.el ends here

;; Local Variables:
;; package-lint-main-file: "ans-mode.el"
;; End:

;; Local Variables:
;; package-lint-main-file: "ans-mode.el"
;; End:
