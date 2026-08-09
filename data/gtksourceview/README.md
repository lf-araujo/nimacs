# Vendored GtkSourceView language definitions

nimacs embeds these `.lang` files at compile time (`staticRead`) and writes them
to `~/.cache/nimacs/language-specs/` at runtime, because the GtkSourceView 5
package on some distributions (e.g. Solus) ships the library **without** its
bundled language definitions. Style schemes are *not* vendored — they are
compiled into `libgtksourceview-5.so` and always available.

## Provenance & licensing

- `language-specs/def.lang`, `language-specs/R.lang`
  From the GNOME **GtkSourceView** project, `data/language-specs/`
  (<https://gitlab.gnome.org/GNOME/gtksourceview>). Licensed **LGPL-2.1-or-later**,
  used unmodified.

- `language-specs/nim.lang`
  Adapted from the `nim.lang` in **StefanSalewski/NEd**
  (<https://github.com/StefanSalewski/NEd>), itself derived from the Nim IDE
  *Aporia*. The only change is mechanical: the pre-build translatable
  attributes `_name=`/`_section=` were rewritten to `name=`/`section=` so the
  GtkSourceView 5 runtime accepts the file. See the upstream project for its
  license.

To refresh the GNOME files, re-fetch from the gtksourceview `master` branch under
`data/language-specs/`.
