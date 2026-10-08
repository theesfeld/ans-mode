# ans-mode

`ans-mode` is an Emacs major mode for ANSI art. Open a `.ans` file and Emacs draws the picture: a VGA font raster, in the colors the file asked for, with the SAUCE title and author in the header line.

Press `t` for a Unicode text view of the same screen. That view can be searched and copied. Saving writes the original file bytes back to disk.

The picture is a still. An ANSiMation is the screen left after the whole stream has been drawn. Blink is kept as a color attribute.

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

Visit a file whose name ends in `.ans`, in any letter case. The mode turns on by itself. The buffer is read-only. Point sits on the picture, and the header line names what you are looking at.

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

`w` asks for a new count for this buffer and draws again. `0` at that prompt, or a prefix argument (`C-u w`), clears the override and returns to SAUCE or 80.

iCE colors turn blink into a bright background, which is what the SAUCE non-blink flag requests. The default follows that flag. A file with no SAUCE record leaves iCE off. `i` flips it for this buffer and draws again. The choice lasts until you toggle it again or kill the buffer. It is not saved as a customization.

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

## Saving and reloading

`C-x C-s` writes the original bytes to the visited file. The rendered text and the raster are a view; they are not the file contents.

`g` reads the file from disk again and draws it. Width, iCE, view, and scale choices you made in the buffer stay in place.

## What the drawing understands

The stream is a CP437 screen. Cursor movement, erase, and a saved cursor write into a fixed number of columns. A character in the last column stays on that row until the next printable character. CR and LF cancel that pending wrap, so a full 80-column line is not followed by a blank one.

Bytes other than CR, LF, TAB, ESC, and SUB (`0x1A`) are CP437 glyphs, including the classic control pictures. TAB advances to the next eighth column.

Colors are the VGA palette. Bold brightens foreground indexes 0–7. With iCE colors on, blink brightens the background the same way. The renderer also accepts the usual SGR attributes (reset, bold, italic, underline, blink, inverse, conceal, and the bright 90–97 / 100–107 indexes), 256-color and 24-bit color, and PabloDraw 24-bit color (`CSI ... t`).

Cursor commands cover `CUP`, up, down, forward, back, horizontal and vertical position, save and restore (`CSI s` / `CSI u` and `ESC 7` / `ESC 8`), erase line, erase display, and `ESC c` to reset.

## License

This program is free software, released under the GNU General Public License, version 3 or any later version. See `LICENSE`.

The 8×16 glyphs are the kbd project's default8x16 console font, in CP437 order. The 8×8 glyphs are the first 256 characters of kbd's drdos8x8 font. Both come from kbd 2.10.0, which is GPL-2.0-or-later, and are included here under that "or later" term.
