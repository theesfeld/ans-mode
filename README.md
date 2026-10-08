# ans-mode

`ans-mode` is an Emacs editor for ANSI art. Open a `.ans` file and Emacs draws the picture: a VGA font raster, in the colors the file asked for, with the SAUCE title and author in the header line.

Press `t` for a Unicode text view of the same screen. That view can be searched and copied. Press `e` to edit the screen: typed characters replace the cell under the cursor. While you edit, the header line shows the pen, the sixteen VGA colors, and the glyphs on F1 through F12. Saving before you edit writes the original file bytes. Saving after you edit writes the screen you see, as ANSi, and keeps the SAUCE title, author, and comments.

The picture is a still. An ANSiMation is the screen left after the whole stream has been drawn. With iCE colors on, blink is a bright background. With iCE colors off, blink stays in the file and the picture stays still.

## Requirements

- Emacs 28.1 or later.
- A graphical Emacs, for the raster. The usual build can display the PPM image this mode creates. In a terminal, the mode uses the text view.

The raster draws with its own VGA bitmaps. You do not need a VGA font installed for that view.

## Install

Activate the package when Emacs starts, before you visit a `.ans` file. Emacs picks the file coding system before it picks the major mode. The package's autoloads mark `.ans` as raw bytes. A file opened earlier in the same session can already be decoded; close it and open it again after the package is active.

Restart Emacs after installing.

### MELPA

Add MELPA to your init file if it is not there yet:

```elisp
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
```

Then refresh the package list and install:

```
M-x package-refresh-contents
M-x package-install RET ans-mode RET
```

With `use-package`:

```elisp
(use-package ans-mode
  :ensure t
  :pin melpa)
```

The MELPA entry is published from the recipe at <https://github.com/melpa/melpa>. Until that recipe is available, `package-install` will not find `ans-mode`. Use one of the GitHub methods below in the meantime. After MELPA lists the package, the same init file works with `:pin melpa`.

### GitHub, Emacs 29 and later

`package-vc` clones the repository and builds the package:

```elisp
(package-vc-install "https://github.com/theesfeld/ans-mode")
```

Evaluate that once. Later upgrades are `M-x package-vc-upgrade`.

On Emacs 30 and later, `use-package` can do the same. `:rev :newest` follows the default branch. Leave `:rev` out to follow the latest version tag.

```elisp
(use-package ans-mode
  :vc (:url "https://github.com/theesfeld/ans-mode"
       :rev :newest))
```

### A clone on `load-path`

```elisp
(add-to-list 'load-path "~/path/to/ans-mode")
(require 'ans-mode)
```

Keep the `require` in your init file so it runs at startup.

If `use-package-always-ensure` is on, tell `use-package` this copy is local:

```elisp
(use-package ans-mode
  :ensure nil
  :load-path "~/path/to/ans-mode")
```

## Open a file

Visit a file whose name ends in `.ans`, in any letter case. The mode turns on by itself. The buffer is read-only. Point sits on the picture, and the header line names what you are looking at. While editing, that line shows the pen and the drawing keys. See [Editing](#editing).

The header line is built from whatever the file records:

- SAUCE title, or the file name when there is no title
- author and group
- date
- rendered columns and rows
- in the raster, the cell size, such as `8×16` or `9×8`
- `iCE` when bright backgrounds are on
- the SAUCE font name
- how many SAUCE comments the file has
- `truncated` when the picture was cut off at `ans-max-rows`
- a short reason when the raster was skipped and the text view is showing

`C-h m` lists the keys for the current buffer.

### Other file names

Only `.ans` is registered. Another suffix needs the same three entries, evaluated at startup:

```elisp
(add-to-list 'auto-mode-alist '("\\.ice\\'" . ans-mode))
(add-to-list 'auto-coding-alist '("\\.ice\\'" . no-conversion))
(add-to-list 'inhibit-local-variables-regexps "\\.ice\\'")
```

`auto-coding-alist` keeps the bytes intact. `inhibit-local-variables-regexps` keeps Emacs from reading a file-local variable block out of the artwork. Change the pattern to the suffix you use.

## The two views

`ans-view` chooses the view for a newly opened file. The default is `image`.

**Raster.** Each character is a VGA glyph. The font is 8×16. A SAUCE font name that contains `VGA50`, `VGA-50`, `80x50`, or `8x8` selects the 8×8 font. Any other name, including Amiga and Topaz, stays on the 8×16 glyphs. The scale is a whole number of screen pixels per font pixel, from 1 to 8. The default scale is 2. Edges stay sharp.

A cell is 8 pixels wide, or 9 when SAUCE asks for 9-pixel spacing or you set `ans-letter-spacing` to 9. In a 9-pixel cell, box-drawing characters (CP437 bytes `#xC0` through `#xDF`) repeat their rightmost column, which is the VGA rule.

Pixels are square. The SAUCE aspect flag is listed in the SAUCE buffer. The raster keeps square pixels.

**Text.** The same cells, as Unicode, with the same foreground and background. `ans-text-font` is applied when that family is installed on a graphical display. The default family is Terminus. Set the option to `nil` to keep your normal default face. The raster does not use this font.

The text view is where search, copy, and point motion work. The raster is one image, so those commands have nothing to land on inside the picture.

Press `t` to switch. `t` again returns to the other view. If the raster cannot be built, the mode switches to text and puts the reason in the echo area and the header line. That happens when the artwork is empty, PPM images are unavailable, or the picture would be larger than `ans-image-max-pixels`.

## Keys

| Key | Command | What it does |
| --- | --- | --- |
| `e` | `ans-edit-mode` | Edit the screen. The header line shows the pen, the VGA colors, and F1–F12. `C-c C-c` leaves edit mode. |
| `t` | `ans-toggle-view` | Switch between the raster and the text view. |
| `+` | `ans-increase-scale` | Make the raster one step larger, up to 8. |
| `-` | `ans-decrease-scale` | Make the raster one step smaller, down to 1. |
| `0` | `ans-reset-scale` | Put the scale back to `ans-image-scale`. |
| `i` | `ans-toggle-ice` | Turn iCE colors on or off and draw again. |
| `w` | `ans-set-width` | Ask for a column count and draw again. |
| `s` | `ans-show-sauce` | Show the SAUCE record in `*ANSI SAUCE*`. |
| `n` | `ans-next-file` | Open the next `.ans` file in this directory. |
| `p` | `ans-previous-file` | Open the previous `.ans` file in this directory. |
| `g` | `revert-buffer` | Read the file from disk and draw it again. |
| `q` | `quit-window` | Close the buffer's window. |
| `SPC` | `scroll-up-command` | Scroll forward. |
| `S-SPC`, `DEL` | `scroll-down-command` | Scroll backward. |

`n` and `p` walk the `.ans` files in the same directory, in alphabetical order, and replace the current buffer. On the first or last file, the echo area says so.

## Configuration

Every option is in the `ans` group:

```
M-x customize-group RET ans RET
```

Set them in your init file if you prefer. This is a complete example:

```elisp
(use-package ans-mode
  :ensure t
  :pin melpa
  :custom
  (ans-view 'image)
  (ans-image-scale 2)
  (ans-letter-spacing 'auto)
  (ans-text-font "Terminus")
  (ans-image-max-pixels 8000000)
  (ans-max-rows 10000))
```

The same settings without `use-package`:

```elisp
(setq ans-view 'image
      ans-image-scale 2
      ans-letter-spacing 'auto
      ans-text-font "Terminus"
      ans-image-max-pixels 8000000
      ans-max-rows 10000)
```

A change to these variables applies the next time a file is drawn. `ans-image-scale` is picked up by `0` in a buffer you already have open. The other options are picked up when you press `g`, toggle a view, or open the file again.

### `ans-view`

Initial view. `image` is the VGA raster. `text` is the Unicode screen.

```elisp
(setq ans-view 'text)
```

### `ans-image-scale`

How many screen pixels stand for one VGA font pixel. `1` is the native glyph size. `2` is the default and is easier to read. The live scale in a buffer moves from 1 to 8 with `+` and `-`. `0` returns it to this value.

```elisp
(setq ans-image-scale 3)
```

### `ans-letter-spacing`

Width of one character cell in the raster.

| Value | Meaning |
| --- | --- |
| `auto` | 9 when SAUCE asks for 9-pixel spacing, otherwise 8. This is the default. |
| `8` | Always 8 pixels. |
| `9` | Always 9 pixels. Box-drawing characters repeat their last column. |

```elisp
(setq ans-letter-spacing 'auto)
```

### `ans-text-font`

Font family for the text view. The default is `"Terminus"`. The family is used only when a graphical display has it installed. `nil` leaves the default face alone.

```elisp
(setq ans-text-font "Terminus")
;; (setq ans-text-font nil)
```

The buffer background is black and the default foreground is VGA light gray (`#AAAAAA`), in both views.

### `ans-image-max-pixels`

Largest raster the mode will build, in font pixels (columns × cell width × rows × glyph height), before scaling. The default is 8000000. A larger picture is shown as text, and the header line says why.

```elisp
(setq ans-image-max-pixels 8000000)
```

### `ans-max-rows`

Largest number of rows the renderer keeps. The default is 10000. A cursor move past that row stays there, and the header line says `truncated`.

```elisp
(setq ans-max-rows 10000)
```

Column count is capped at 4096.

## Width and iCE colors

With no other instruction, the column count comes from the SAUCE record of a character file (ASCII, ANSi, or ANSiMation). A missing or zero width uses 80 columns.

`w` asks for a new count for this buffer. Before you edit, the stream is read again at that width. After you edit, the grid changes width and the cells on the left of each row stay. `0` at that prompt, or a prefix argument (`C-u w`), clears the override and returns to SAUCE or 80. After an edit, that restore still resizes the grid you have.

iCE colors turn blink into a bright background, which is what the SAUCE non-blink flag requests. The default follows that flag. A file with no SAUCE record leaves iCE off. `i` flips it for this buffer. Before you edit, the stream is read again, so blink and bright backgrounds trade places. After you edit, the cells keep the colors they have and the flag stored on save changes. The choice lasts until you toggle it again or kill the buffer. It is not saved as a customization.

## SAUCE

`s` opens `*ANSI SAUCE*`. When the file has a record, the buffer lists:

- title, author, group, and date
- data type and file type
- font name
- the size stored in the record, and the size actually drawn
- whether iCE colors are on
- letter spacing: 8-pixel, 9-pixel, or legacy
- the aspect flag: legacy, legacy device, square pixels, or invalid
- file size
- the comment lines

A file with no record still opens. That buffer says so, and reports the rendered size and whether iCE colors are on.

Comments are also counted in the header line. The artwork itself stops before the SAUCE record, a preceding comment block, and a preceding EOF byte (`0x1A`).

## Editing

`e` turns on editing. The header line becomes the drawing bar. From left to right it shows:

- the cursor, as `row,column`, counting from 1
- the pen: two blocks in the current foreground and background, then the color names, and `ul` when underline is on
- sixteen VGA color chips, black on the left through white on the right
- the drawing-set name
- the glyph on each of F1 through F12

Click a chip to take that foreground. Right-click a chip to take that background. The foreground chip has a light or dark rim, and the background chip has a gold rim. Roll the mouse wheel on the bar to cycle the foreground. Hold Meta and roll the wheel to cycle the background.

`M-right` and `M-left` cycle the foreground. `M-up` and `M-down` cycle the background. A pen that holds a 256-color or 24-bit value returns to the VGA set on the first cycle. Foreground continues from light gray, and background continues from black.

`C-c C-f` and `C-c C-b` read one key. The echo area shows `0` through `9` and `A` through `F`, each digit drawn in that VGA color. Press the digit you want. `RET` keeps the current VGA color. `C-g` cancels.

F1 through F12 type the glyph the bar shows for that key. While you are editing, those keys are drawing keys. `M-n` shows the next drawing set, and `M-p` shows the previous one. Click the set name for the next set. Right-click the name for the previous set.

| Set | F1 | F2 | F3 | F4 | F5 | F6 | F7 | F8 | F9 | F10 | F11 | F12 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Blocks | ░ | ▒ | ▓ | █ | ▀ | ▄ | ▌ | ▐ | ■ | · | • | ∙ |
| Double lines | ╔ | ╗ | ╚ | ╝ | ═ | ║ | ╠ | ╣ | ╦ | ╩ | ╬ | █ |
| Single lines | ┌ | ┐ | └ | ┘ | ─ | │ | ├ | ┤ | ┬ | ┴ | ┼ | █ |

Editing starts on Blocks. In the raster the current cell is inverted. In the text view the Emacs cursor sits on that cell. Click a cell to move there.

Typing replaces that cell and moves to the next one. At the right edge the cursor wraps to the next row, and a new row is added when you type or move past the last one. The picture is a fixed grid: a new character overwrites the cell. It does not push the rest of the line sideways.

| Key | What it does while editing |
| --- | --- |
| letters, numbers, punctuation, `SPC` | Write that CP437 glyph with the current pen. |
| `F1`–`F12` | Write the glyph shown for that key on the bar. |
| arrows, `C-f`, `C-b`, `C-n`, `C-p` | Move one cell. |
| `M-right`, `M-left` | Next and previous foreground. |
| `M-up`, `M-down` | Next and previous background. |
| `M-n`, `M-p` | Next and previous drawing set. |
| `C-a`, `Home` | First column of this row. |
| `C-e`, `End` | Last drawn cell on this row. |
| `TAB` | Next eighth column. |
| `RET` | First column of the next row. |
| `DEL`, `Backspace` | Move back one cell and paint a space with the pen. |
| `C-/`, `C-_`, `C-x u` | Undo the last cell change. |
| `C-?` | Redo the cell change just undone. |
| `C-c C-f` | Set the foreground from one hex digit, 0 through F. |
| `C-c C-b` | Set the background from one hex digit, 0 through F. |
| `C-c C-u` | Toggle underline for cells typed from now on. |
| `C-c C-p` | Copy the current cell's colors into the pen. |
| `C-c C-t` | Switch between the raster and the text view. |
| `C-c C-i` | Toggle the iCE-colors flag. After an edit, cells keep their colors. |
| `C-c C-s` | Show the SAUCE record. |
| `C-c C-w` | Set the column count. After an edit, the grid is resized. |
| `C-c C-r` | Reload the file from disk and discard edits. |
| `C-c C-c` | Leave edit mode. `F1`–`F12` return to their usual commands. |

The palette is the VGA set. 0 is black, 1 red, 2 green, 3 brown, 4 blue, 5 magenta, 6 cyan, 7 light gray. 8 through 15 are the bright versions of those, ending at 15 white. A background of 8 through 15 is a bright background.

`C-c C-p` can pick a 256-color or 24-bit color out of an existing cell. The next characters you type keep that color. `C-c C-f`, `C-c C-b`, a click on a chip, or a meta-arrow returns the pen to a VGA index.

Viewer keys such as `t` and `s` type those letters while you are editing. Use the `C-c C-` bindings above for those commands, then `C-c C-c` when you want the viewer keys back.

A glyph that has no CP437 byte is refused. Tab, line feed, carriage return, the DOS end-of-file byte, and escape are controls in an ANSI stream, so those five CP437 pictures cannot be stored in the file.

## Saving and reloading

`C-x C-s` before you edit writes the original bytes to the visited file. An ANSiMation stays the original stream.

`C-x C-s` after you edit writes the screen as an ANSi file. Each row is CP437 and SGR color codes, then CR LF. An EOF byte (`0x1A`) follows the artwork, then a COMNT block when the file has comments, then the 128-byte SAUCE record.

The saved record is SAUCE version 00, Character / ANSi:

- Title, author, group, date, and comments stay. Those fields are CP437 and padded with spaces.
- The font name stays. It is stored as a NUL-padded string of 22 bytes. A new file uses `IBM VGA`.
- The column count and the row count match the screen. TInfo3 and TInfo4 are 0.
- Letter spacing and the aspect flag stay. Reserved flag bits are 0. The iCE bit matches the screen.
- FileSize is the length of the artwork. The EOF byte and the SAUCE record are appended after that artwork.

The saved file is a still. An ANSiMation's original stream is replaced by that still when you save an edit. With iCE colors off, a blinking cell is written back as SGR 5. With iCE colors on, that blink is the bright background already shown.

`g` outside edit mode, and `C-c C-r` while editing, read the file from disk again and discard edits. Width, iCE, view, and scale choices you made in the buffer stay in place.

## What the drawing understands

The stream is a CP437 screen. Cursor movement, erase, and a saved cursor write into a fixed number of columns. A character in the last column stays on that row until the next printable character. CR and LF cancel that pending wrap, so a full 80-column line is not followed by a blank one. LF also moves to the first column of the next row.

Bytes other than CR, LF, TAB, ESC, and SUB (`0x1A`) are CP437 glyphs, including the classic control pictures. TAB advances to the next eighth column. SUB ends the stream.

Colors are the VGA palette. Bold brightens foreground indexes 0–7. With iCE colors on, blink brightens the background the same way. With iCE colors off, blink stays on the cell and a later save writes SGR 5. The picture stays still either way. The renderer also accepts the usual SGR attributes (reset, bold, italic, underline, blink, inverse, conceal, and the bright 90–97 / 100–107 indexes), 256-color and 24-bit color (`38;5`, `38;2`, `48;5`, `48;2`), and PabloDraw 24-bit color (`CSI 0;R;G;B t` for the background and `CSI 1;R;G;B t` for the foreground).

Cursor commands cover `CUP`, up, down, forward, back, horizontal and vertical position, save and restore (`CSI s` / `CSI u` and `ESC 7` / `ESC 8`), erase line, erase display, and `ESC c` to reset.

An ANSiMation is the still left after the whole stream. Saving an edit writes that still as ANSi, file type 1.

This mode reads and writes CP437 ANSi streams and their SAUCE records. SAUCE follows [revision 00.5](https://www.acid.org/info/sauce/sauce.htm): version `00`, space-padded character fields, a NUL-padded font name, and the ANSi flag bits for iCE colors, letter spacing, and aspect. The row count in an ANSi record is a hint. The drawn height comes from the stream. A width of 0 uses 80 columns. PCBoard, Avatar, RIP, TundraDraw palettes, BinaryText, and XBin are outside this reader. Amiga and Topaz names use the VGA 8×16 glyphs. The aspect flag is reported in the SAUCE buffer, and the raster keeps square pixels.

## License

This program is free software, released under the GNU General Public License, version 3 or any later version. See `LICENSE`.

The 8×16 glyphs are the kbd project's default8x16 console font, in CP437 order. The 8×8 glyphs are the first 256 characters of kbd's drdos8x8 font. Both come from kbd 2.10.0, which is GPL-2.0-or-later, and are included here under that "or later" term.
