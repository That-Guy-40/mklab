/* grub/datetime.h — minimal grub2fs shim: struct grub_datetime +
 * grub_datetime2unixtime, which fat.c/iso9660.c call to turn a directory
 * entry's date into an mtime.
 *
 * The struct and the inline below are COPIED VERBATIM from GRUB 2.12
 * include/grub/datetime.h (GPLv3+, lab-only — see upstream-grub/README.md);
 * the inline is self-contained, so the shim carries just it rather than the
 * full header's get/set-datetime declarations the drivers do not call. */
#ifndef GRUB2FS_GRUB_DATETIME_H
#define GRUB2FS_GRUB_DATETIME_H

#include <grub/types.h>
#include <grub/err.h>

struct grub_datetime
{
  grub_uint16_t year;
  grub_uint8_t month;
  grub_uint8_t day;
  grub_uint8_t hour;
  grub_uint8_t minute;
  grub_uint8_t second;
};

static inline int
grub_datetime2unixtime (const struct grub_datetime *datetime, grub_int64_t *nix)
{
  grub_int32_t ret;
  int y4, ay;
  const grub_uint16_t monthssum[12]
    = { 0,
	31,
	31 + 28,
	31 + 28 + 31,
	31 + 28 + 31 + 30,
	31 + 28 + 31 + 30 + 31,
	31 + 28 + 31 + 30 + 31 + 30,
	31 + 28 + 31 + 30 + 31 + 30 + 31,
	31 + 28 + 31 + 30 + 31 + 30 + 31 + 31,
	31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30,
	31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31,
	31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30};
  const grub_uint8_t months[12] = {31, 28, 31, 30, 31, 30,
				   31, 31, 30, 31, 30, 31};
  const int SECPERMIN = 60;
  const int SECPERHOUR = 60 * SECPERMIN;
  const int SECPERDAY = 24 * SECPERHOUR;
  const int SECPERYEAR = 365 * SECPERDAY;
  const int SECPER4YEARS = 4 * SECPERYEAR + SECPERDAY;

  if (datetime->year > 2038 || datetime->year < 1901)
    return 0;
  if (datetime->month > 12 || datetime->month < 1)
    return 0;

  ret = 3 * SECPERYEAR + SECPERDAY;

  y4 = ((datetime->year - 1) >> 2) - (1973 / 4);
  ay = datetime->year - 1973 - 4 * y4;
  ret += y4 * SECPER4YEARS;
  ret += ay * SECPERYEAR;

  ret += monthssum[datetime->month - 1] * SECPERDAY;
  if (ay == 3 && datetime->month >= 3)
    ret += SECPERDAY;

  ret += (datetime->day - 1) * SECPERDAY;
  if ((datetime->day > months[datetime->month - 1]
       && (!ay || datetime->month != 2 || datetime->day != 29))
      || datetime->day < 1)
    return 0;

  ret += datetime->hour * SECPERHOUR;
  if (datetime->hour > 23)
    return 0;
  ret += datetime->minute * 60;
  if (datetime->minute > 59)
    return 0;

  ret += datetime->second;
  /* Accept leap seconds.  */
  if (datetime->second > 60)
    return 0;

  if ((datetime->year > 1980 && ret < 0)
      || (datetime->year < 1960 && ret > 0))
    return 0;
  *nix = ret;
  return 1;
}

#endif /* GRUB2FS_GRUB_DATETIME_H */
