/* imx708_gain_shim.c -- LD_PRELOAD: translate TI's auto-exposure gain codes
 * from IMX219 units to IMX708 units.
 *
 * WHY.  TI ships no IMX708 support in its ISP stack, so the pipeline runs
 * tiovxisp as SENSOR_SONY_IMX219_RPI.  Its 2A loop then drives the sensor
 * over V4L2 using the IMX219's analogue-gain register law:
 *
 *     IMX219:  code = 256  - 256  / G        (G = 1x..8x  ->  code 0..224)
 *     IMX708:  code = 1024 - 1024 / G        (G = 1x..16x ->  code 112..960)
 *
 * Same law, different scale -- so the AE's "8x, flat out" (224) lands on the
 * IMX708 as about 1.3x.  Measured on hardware 2026-09-17: exposure pinned at
 * its maximum, analogue_gain pinned at 224 of a possible 960, and the night
 * image black (mean luma 0.3) with the loop convinced it had nothing left to
 * give.  Writing the control by hand does not help: the loop rewrites it
 * within a frame or two.
 *
 * The algebra is exact:   code708 = 1024 - 4*(256 - code219) = 4 * code219
 * so this multiplies by four and clamps to the driver's range.  Nothing else
 * is touched; every other ioctl passes straight through.
 *
 * This is a stopgap with a clear exit: a real IMX708 DCC + sensor entry in the
 * ISP stack makes it unnecessary, at which point delete it from cam_run.sh.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>
#include <linux/v4l2-controls.h>

#define IMX708_GAIN_MIN 112
#define IMX708_GAIN_MAX 960

static int fix(int v)
{
    v *= 4;
    if (v < IMX708_GAIN_MIN) v = IMX708_GAIN_MIN;
    if (v > IMX708_GAIN_MAX) v = IMX708_GAIN_MAX;
    return v;
}

int ioctl(int fd, unsigned long req, ...)
{
    static int (*real)(int, unsigned long, ...);
    va_list ap;
    va_start(ap, req);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    if (!real) real = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");

    if (arg && req == VIDIOC_S_CTRL) {
        struct v4l2_control *c = arg;
        if (c->id == V4L2_CID_ANALOGUE_GAIN) {
            struct v4l2_control t = *c;
            t.value = fix(c->value);
            return real(fd, req, &t);      /* caller's struct left untouched */
        }
    } else if (arg && req == VIDIOC_S_EXT_CTRLS) {
        struct v4l2_ext_controls *e = arg;
        for (unsigned i = 0; e->controls && i < e->count; i++)
            if (e->controls[i].id == V4L2_CID_ANALOGUE_GAIN)
                e->controls[i].value = fix(e->controls[i].value);
    }
    return real(fd, req, arg);
}
