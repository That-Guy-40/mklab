/* grub/charset.h — minimal grub2fs shim: just grub_utf16_to_utf8, which
 * fat.c/iso9660.c call to render UTF-16 long names / Joliet as UTF-8.
 *
 * The inline below is COPIED VERBATIM from GRUB 2.12 include/grub/charset.h
 * (GPLv3+, lab-only — see upstream-grub/README.md); it is self-contained (uses
 * only grub types), so the shim carries just it rather than the full 323-line
 * header of charset routines the drivers do not call. */
#ifndef GRUB2FS_GRUB_CHARSET_H
#define GRUB2FS_GRUB_CHARSET_H

#include <grub/types.h>

#define GRUB_MAX_UTF8_PER_UTF16 4

/* Convert UTF-16 to UTF-8. Returns the byte after the last written. */
static inline grub_uint8_t *
grub_utf16_to_utf8 (grub_uint8_t *dest, const grub_uint16_t *src,
		    grub_size_t size)
{
  grub_uint32_t code_high = 0;

  while (size--)
    {
      grub_uint32_t code = *src++;

      if (code_high)
	{
	  if (code >= 0xDC00 && code <= 0xDFFF)
	    {
	      /* Surrogate pair.  */
	      code = ((code_high - 0xD800) << 10) + (code - 0xDC00) + 0x10000;

	      *dest++ = (code >> 18) | 0xF0;
	      *dest++ = ((code >> 12) & 0x3F) | 0x80;
	      *dest++ = ((code >> 6) & 0x3F) | 0x80;
	      *dest++ = (code & 0x3F) | 0x80;
	    }
	  else
	    {
	      /* Error...  */
	      *dest++ = '?';
	      /* *src may be valid. Don't eat it.  */
	      src--;
	    }

	  code_high = 0;
	}
      else
	{
	  if (code <= 0x007F)
	    *dest++ = code;
	  else if (code <= 0x07FF)
	    {
	      *dest++ = (code >> 6) | 0xC0;
	      *dest++ = (code & 0x3F) | 0x80;
	    }
	  else if (code >= 0xD800 && code <= 0xDBFF)
	    {
	      code_high = code;
	      continue;
	    }
	  else if (code >= 0xDC00 && code <= 0xDFFF)
	    {
	      /* Error... */
	      *dest++ = '?';
	    }
	  else if (code < 0x10000)
	    {
	      *dest++ = (code >> 12) | 0xE0;
	      *dest++ = ((code >> 6) & 0x3F) | 0x80;
	      *dest++ = (code & 0x3F) | 0x80;
	    }
	  else
	    {
	      *dest++ = (code >> 18) | 0xF0;
	      *dest++ = ((code >> 12) & 0x3F) | 0x80;
	      *dest++ = ((code >> 6) & 0x3F) | 0x80;
	      *dest++ = (code & 0x3F) | 0x80;
	    }
	}
    }

  return dest;
}

#endif /* GRUB2FS_GRUB_CHARSET_H */
