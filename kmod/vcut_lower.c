// SPDX-License-Identifier: GPL-2.0
/*
 * vcut_lower.c - VCut Lower compatible control backend for xaga / MT6895
 *
 * The original VCut Lower hooks Xiaomi MCA (business-votable, strategy-fg,
 * fg_master).  xaga has none of those; it uses MTK pmic-votable + bq28z610.
 *
 * This module keeps the *userspace ABI* that vcutlower.apk expects
 * (/sys/module/vcut_lower/parameters/*) and implements it with xaga primitives:
 *
 *   - vcut_fw / vcut_delay / vcut_sw : software CAPACITY floor.  xaga has no
 *     gauge DF path, so vcut_fw is accepted for compatibility but the actual
 *     gate is vcut_delay.
 *   - soc_ctl                         : rm/fcc real SOC takeover
 *   - force_ma                        : force charger current (turbo B)
 *   - vcut_lower.ko hooks             : vote()/set_cv for 4.53V, fg_get_property
 *                                       for capacity, get_effective_result and
 *                                       charger_dev_set_charging_current for
 *                                       forced current.
 *
 * Only xaga 5.10 is supported.  No multi-device/MCA compatibility code.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/string.h>
#include <linux/moduleparam.h>
#include <linux/version.h>
#include <linux/uaccess.h>
#include <linux/power_supply.h>
#include <linux/workqueue.h>
#include <linux/ktime.h>
#include <linux/kobject.h>

MODULE_LICENSE("GPL v2");
MODULE_AUTHOR("xaga-vcut");
MODULE_DESCRIPTION("VCut Lower ABI on xaga MT6895 (pmic-votable + bq28z610)");

/* ---- userspace ABI expected by vcutlower.apk ------------------------- */

static int enable = 1;
module_param(enable, int, 0644);
MODULE_PARM_DESC(enable, "0=observe only, 1=apply capacity/current hooks");

static int vcut_fw = 3000;
module_param(vcut_fw, int, 0644);
MODULE_PARM_DESC(vcut_fw, "gauge cutoff mV (accepted; xaga has no DF path)");

static int vcut_delay = 3000;
module_param(vcut_delay, int, 0644);
MODULE_PARM_DESC(vcut_delay, "actual software shutdown floor in mV");

static int vcut_sw = 2900;
module_param(vcut_sw, int, 0644);
MODULE_PARM_DESC(vcut_sw, "UI-empty threshold mV (reported only)");

static int kill_vpack_gate = 1;
module_param(kill_vpack_gate, int, 0644);
MODULE_PARM_DESC(kill_vpack_gate, "accepted for ABI compatibility (no-op)");

static int soc_ctl = 1;
module_param(soc_ctl, int, 0644);
MODULE_PARM_DESC(soc_ctl, "1=report real SOC from rm/fcc");

static int fake_cycle = -1;
module_param(fake_cycle, int, 0644);
MODULE_PARM_DESC(fake_cycle, "accepted for ABI; service writes bms/cycle_count");

static int fake_fg_cycle = -1;
module_param(fake_fg_cycle, int, 0644);
MODULE_PARM_DESC(fake_fg_cycle, "accepted for ABI; service writes bms/cycle_count");

static int fcc_mah = 0;
module_param(fcc_mah, int, 0644);
MODULE_PARM_DESC(fcc_mah, "0=read live CHARGE_FULL, >0=override mAh");

static int qbot_mah = 0;
module_param(qbot_mah, int, 0644);
MODULE_PARM_DESC(qbot_mah, "bottom compensation mAh");

/*
 * Real coulomb integration (plan B).
 *
 * The gauge on this phone reports a DESIGN capacity of 4400 mAh while the
 * cell actually holds ~5400 mAh.  Its RM decreases perfectly linearly
 * (456 mAh per 10% SOC no matter what the load does), i.e. the gauge is
 * NOT integrating charge -- it walks a model.  Consequence: SOC drifts
 * away from the real charge left in the cell, and it reaches 0 while the
 * pack still has usable energy above the 3.4V shutdown floor.
 *
 * true_mah  : real full-charge capacity we integrate against.
 * coul_ctl  : 0 = integrate and expose t_coul_* read-only (safe),
 *             1 = let the integration own CAPACITY.
 * Both default to "off / read-only" so a flashed module is inert until
 * the numbers have been validated on a real discharge run.
 */
static int true_mah = 6000;
module_param(true_mah, int, 0644);
MODULE_PARM_DESC(true_mah, "real full capacity mAh used by coulomb mode");

static int coul_ctl = 0;
module_param(coul_ctl, int, 0644);
MODULE_PARM_DESC(coul_ctl, "1=CAPACITY driven by coulomb integration");

static int rint_mohm = 28;
module_param(rint_mohm, int, 0644);
MODULE_PARM_DESC(rint_mohm, "accepted for ABI compatibility");

static int fv_target_mv = 4475;
module_param(fv_target_mv, int, 0644);
MODULE_PARM_DESC(fv_target_mv, "absolute FV target mV");

static int fv_max_mv = 4580;
module_param(fv_max_mv, int, 0644);
MODULE_PARM_DESC(fv_max_mv, "FV ceiling mV");

static int force_ma = 0;
module_param(force_ma, int, 0644);
MODULE_PARM_DESC(force_ma, "force charger current mA, 0=off (turbo B)");

static int verbose = 0;
module_param(verbose, int, 0644);
MODULE_PARM_DESC(verbose, "log every adjustment");

/*
 * 临时取消本次关机倒计时。
 *
 * 1 = 用户在 App 里按了"临时取消"：本轮不再发 POWER_SUPPLY_SHUTDOWN_DELAY=1，
 *     若倒计时已经跑起来则补发一次 =0 把它撤掉；本轮不再重新触发。
 *
 * 它是闩锁而不是开关：电压回到 vcut_delay 以上、或插上充电器时 shut_tick
 * 自动把它清 0，所以只影响"当前这一轮放电到闸以下"，下一轮照常触发。
 * 取消之后不再做任何事——是否关机交回系统（BatteryService 的
 * shutdown,battery 硬关机路径完全不参与这里）。
 */
static int shut_skip = 0;
module_param(shut_skip, int, 0644);
MODULE_PARM_DESC(shut_skip, "1=cancel the current 30s shutdown countdown (auto-clears above floor or on charger)");

/* ---- telemetry ABI --------------------------------------------------- */

#define TELEM_RO(name, init) \
	static int name = init; \
	module_param(name, int, 0444)

TELEM_RO(t_resolved, 1);
TELEM_RO(t_delta, 0);
TELEM_RO(t_off_src, 0);
TELEM_RO(t_anchors, 0);
TELEM_RO(t_scan_insns, 0);
TELEM_RO(t_gate_ok, 1);
TELEM_RO(t_ovr, 0);
TELEM_RO(t_cyc_ok, 1);
TELEM_RO(t_mean_volt, 0);
TELEM_RO(t_current, 0);
TELEM_RO(t_vpack, 0);
TELEM_RO(t_soc, 0);
TELEM_RO(t_temp, 0);
TELEM_RO(t_vbatt_empty, 0);
TELEM_RO(t_fake_soc, -1);
TELEM_RO(t_hits, 0);
TELEM_RO(armed, 0);
TELEM_RO(t_orig_delay, 3400);
TELEM_RO(t_wrote, 0);
TELEM_RO(t_failsafe, 0);
TELEM_RO(t_no_kick, 0);
TELEM_RO(t_fcc, 0);
TELEM_RO(t_rm, 0);
TELEM_RO(t_handoff_cnt, 0);
TELEM_RO(t_soc_real, -1);
TELEM_RO(t_raw_soc, 0);
TELEM_RO(t_disp, 0);
TELEM_RO(t_cycle, 0);
TELEM_RO(t_fg_cycle, 0);
TELEM_RO(t_fg_cyc_hits, 0);
TELEM_RO(fg_cyc_armed, 0);
TELEM_RO(t_cross_seq, 0);
TELEM_RO(t_cross_rm, 0);
TELEM_RO(t_cross_mv, 0);
TELEM_RO(t_cross_ma, 0);
TELEM_RO(t_cross_temp, 0);
TELEM_RO(t_cross_stock, 3400);
TELEM_RO(t_cross_delay, 3000);
TELEM_RO(t_below_mah, 0);
TELEM_RO(t_below_min_mv, 0);
TELEM_RO(vc_armed, 0);
TELEM_RO(t_vc_hits, 0);
TELEM_RO(t_coul_mah, 0);
TELEM_RO(t_coul_soc, -1);
TELEM_RO(t_coul_base, -1);
TELEM_RO(t_coul_state, 0);
TELEM_RO(t_coul_ma, 0);
TELEM_RO(t_learn_mah, 0);
TELEM_RO(t_shut_sent, 0);
TELEM_RO(t_shut_ue, -1);
TELEM_RO(t_shut_mv, 0);
TELEM_RO(t_shut_skip, 0);

/* ---- helpers --------------------------------------------------------- */

#define XAGA_PROP_CHARGE_FULL		24
#define XAGA_PROP_CHARGE_COUNTER	28
#define XAGA_PROP_CAPACITY		46
#define XAGA_PROP_CYCLE_COUNT		7

struct votable;

static int t_mv;		/* last voltage sample (mV) */
static int t_soc_real;		/* last real SOC (0..100), -1=unknown */
static bool cross_active;
static int cross_rm_mah;
static int cross_min_mv;

/* ---- coulomb integrator state (plan B) ------------------------------- */

static int clamp_int(int v, int lo, int hi);

static s64 coul_uah;		/* signed charge since base, + = discharged */
static u64 coul_last_ms;	/* last integration timestamp */
static int coul_base_soc = -1;	/* SOC captured when the base was armed */
static bool coul_armed;		/* base captured for this discharge run */
static bool coul_full_latch;	/* already re-based on this full-charge event */
static int  coul_learn_pending;	/* a clean full-charge run is in flight */
static int  coul_learn_measured;	/* last run's capacity, applied at next arm */
static bool coul_charged_since_arm;	/* topped up mid-run -> measurement void */
static int  coul_quiet_sec;		/* consecutive seconds at rest */
static u64  coul_last_calib_ms;	/* last OCV re-base, for rate limiting */

/*
 * Fold one current sample into the charge accumulator.  POWER_SUPPLY's
 * CURRENT_NOW is in uA (not mA), so with dt in ms:
 *   uA * ms / 3600000 = uAh      (1 A for 1 s = 1 C = 0.2778 mAh)
 * Positive current discharges (see mtk_charger: charging is negative),
 * so the accumulator grows while running on battery and shrinks while
 * plugged in.
 */
static void coul_fold(int ua, u64 dt_ms)
{
	if (dt_ms == 0 || dt_ms > 60000)
		return;
	coul_uah += (s64)ua * (s64)dt_ms / 3600000;
}

/* Recompute the coulomb-mode SOC from the accumulator; -1 = not armed. */
static int coul_soc_now(void)
{
	s64 full_uah, remain;

	if (!coul_armed || coul_base_soc < 0 || true_mah <= 0)
		return -1;
	full_uah = (s64)true_mah * 1000;
	if (full_uah <= 0)
		return -1;
	/* base_soc is where the run started; discharge only moves downward */
	remain = (s64)coul_base_soc * full_uah / 100 - coul_uah;
	return clamp_int((int)((remain * 100 + full_uah / 2) / full_uah), 0, 100);
}

/*
 * Open-circuit voltage -> SOC, anchored on the 17.1h full-discharge
 * run (2026-11-12: 4505mV/100% down to a 2915mV shutdown, 6024mAh
 * released).  Voltage is a chemistry property, independent of how
 * much capacity the cell still has -- exactly what an ageing pack
 * needs: it lets the integration be re-based without having to pin
 * true_mah precisely.
 *
 * Only trustworthy at rest.  Under load the IR drop pulls the
 * reading down by tens of mV, which is why the caller requires five
 * minutes of |I| < 100mA before reconciling.
 */
static const struct { int mv; int soc; } ocv_tbl[] = {
	{ 4450, 100 }, { 4400, 98 }, { 4300, 88 }, { 4200, 76 },
	{ 4100, 66 }, { 4000, 58 }, { 3950, 54 }, { 3900, 49 },
	{ 3850, 43 }, { 3800, 38 }, { 3750, 33 }, { 3700, 28 },
	{ 3650, 24 }, { 3600, 21 }, { 3550, 17 }, { 3500, 13 },
	{ 3450, 11 }, { 3400, 10 }, { 3350, 6 }, { 3300, 4 },
	{ 3250, 2 }, { 3200, 1 },
};

static int ocv_to_soc(int mv)
{
	int i;

	if (mv <= 0)
		return -1;
	if (mv >= ocv_tbl[0].mv)
		return 100;
	for (i = 1; i < (int)ARRAY_SIZE(ocv_tbl); i++) {
		if (mv >= ocv_tbl[i].mv) {
			int hi = ocv_tbl[i - 1].mv, lo = ocv_tbl[i].mv;
			int sh = ocv_tbl[i - 1].soc, sl = ocv_tbl[i].soc;

			return sl + (mv - lo) * (sh - sl) / (hi - lo);
		}
	}
	return 0;
}

/* (Re)arm the base: full charge, or the SOC we happened to unplug at. */
static void coul_arm(int base_soc, int ma, int mv)
{
	/*
	 * A capacity measured on the previous complete run is applied
	 * here, at a re-base point, never mid-discharge: changing
	 * true_mah while coul_uah is non-zero would make the reported
	 * percentage jump.
	 *
	 * true_mah is a self-learning estimate, not a constant.  Li-ion
	 * cells lose capacity with age, temperature and cycling, so a
	 * clean full->empty run (>= 99% base, never charged in between,
	 * sane temperature, sane measured value) feeds back a
	 * 1/4-weighted EMA.  Four full cycles converge on a changed
	 * cell; one bad run only nudges the estimate.
	 */
	if (coul_learn_measured > 0) {
		pr_info("vcut_lower: capacity learn %d -> %d mAh\n",
			true_mah, coul_learn_measured);
		true_mah = coul_learn_measured;
		coul_learn_measured = 0;
		WRITE_ONCE(t_learn_mah, 0);
	}

	coul_uah = 0;
	coul_last_ms = 0;
	coul_base_soc = clamp_int(base_soc, 0, 100);
	coul_armed = true;
	WRITE_ONCE(t_coul_base, coul_base_soc);
	WRITE_ONCE(t_coul_state, 2);
	WRITE_ONCE(t_coul_ma, ma / 1000);
	coul_learn_pending = (coul_base_soc >= 99);
	coul_charged_since_arm = false;
	pr_info("vcut_lower: coul base armed soc=%d ma=%d mv=%d true_mah=%d\n",
		coul_base_soc, ma / 1000, mv, true_mah);
}

static void coul_disarm(void)
{
	coul_armed = false;
	coul_base_soc = -1;
	coul_uah = 0;
	coul_last_ms = 0;
	WRITE_ONCE(t_coul_base, -1);
	WRITE_ONCE(t_coul_soc, -1);
	WRITE_ONCE(t_coul_state, 0);
}

static bool kstr_is(unsigned long ptr, const char *want)
{
	char buf[32];
	int i;

	if (ptr < 0xffff000000000000UL)
		return false;

	for (i = 0; i < (int)sizeof(buf) - 1; i++) {
		char c;

		if (copy_from_kernel_nofault(&c, (const void *)(ptr + i), 1))
			return false;
		buf[i] = c;
		if (c == '\0')
			break;
	}
	buf[i] = '\0';
	return strcmp(buf, want) == 0;
}

static bool votable_name_is(unsigned long votable, const char *want)
{
	unsigned long name = 0;

	if (votable < 0xffff000000000000UL)
		return false;
	if (copy_from_kernel_nofault(&name, (const void *)votable,
				     sizeof(name)))
		return false;
	if (!name)
		return false;
	return kstr_is(name, want);
}

static int clamp_int(int v, int lo, int hi)
{
	if (v < lo)
		return lo;
	if (v > hi)
		return hi;
	return v;
}

/* ---- FV hooks -------------------------------------------------------- */

struct votable;

extern struct votable *find_votable(const char *name);
extern int vote(struct votable *votable, const char *client_str,
		bool enabled, int val);
extern int get_client_vote(struct votable *votable, const char *client_str);
extern int get_effective_result(struct votable *votable);

static int vote_pre_handler(struct kprobe *p, struct pt_regs *regs)
{
	unsigned long client_ptr = regs->regs[1];
	int enabled = (int)regs->regs[2];
	int val = (int)regs->regs[3];
	int new_val = val;
	int target;

	if (!enable || !enabled || fv_target_mv <= 0)
		return 0;

	target = clamp_int(fv_target_mv, 4000, fv_max_mv);
	if (kstr_is(client_ptr, "FFC_VOTER") ||
	    kstr_is(client_ptr, "JEITA_CHARGE_VOTER")) {
		if (val >= 4000 && val <= 5000) {
			new_val = target;
			if (new_val != val) {
				regs->regs[3] = (unsigned long)(long)new_val;
				if (verbose)
					pr_info("vcut_lower: FV vote %d -> %d\n",
						val, new_val);
			}
		}
	}
	return 0;
}

static struct kprobe kp_vote = {
	.symbol_name = "vote",
	.pre_handler = vote_pre_handler,
};

static int set_cv_pre_handler(struct kprobe *p, struct pt_regs *regs)
{
	long uv = (long)regs->regs[1];
	long mv, new_mv;

	if (!enable || fv_target_mv <= 0 || uv < 4000000 || uv > 5000000)
		return 0;

	mv = uv / 1000;
	new_mv = clamp_int(fv_target_mv, 4000, fv_max_mv);
	if (new_mv != mv) {
		regs->regs[1] = (unsigned long)(new_mv * 1000);
		if (verbose)
			pr_info("vcut_lower: set_cv %ld -> %ld mV\n", mv, new_mv);
	}
	return 0;
}

static struct kprobe kp_setcv = {
	.symbol_name = "charger_dev_set_constant_voltage",
	.pre_handler = set_cv_pre_handler,
};

/* ---- forced current (turbo B) --------------------------------------- */

/*
 * xaga exposes CHARGER_FCC/force_active read-only in debugfs, so the original
 * vcut_turbo.sh cannot use it.  We implement the same semantic in-kernel:
 * get_effective_result() reports force_ma, and charger_dev_set_charging_current()
 * is rewritten so the charger IC receives it even if the votable call is LTO'd.
 *
 * vcut_turbo.sh owns all guard rails and writes force_ma=0 to release.
 */
static int eff_entry_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	unsigned long *v = (unsigned long *)ri->data;

	*v = regs->regs[0];
	return 0;
}

static int eff_ret_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	unsigned long *v = (unsigned long *)ri->data;

	if (enable && force_ma > 0 &&
	    votable_name_is(*v, "CHARGER_FCC"))
		regs->regs[0] = (unsigned long)(long)clamp_int(force_ma, 0, 21500);
	return 0;
}

static struct kretprobe krp_eff = {
	.kp.symbol_name = "get_effective_result",
	.entry_handler = eff_entry_handler,
	.handler = eff_ret_handler,
	.data_size = sizeof(unsigned long),
	.maxactive = 32,
};

/* pmic-votable debugfs and some internal callers use the _locked variant. */
static struct kretprobe krp_eff_locked = {
	.kp.symbol_name = "get_effective_result_locked",
	.entry_handler = eff_entry_handler,
	.handler = eff_ret_handler,
	.data_size = sizeof(unsigned long),
	.maxactive = 32,
};

static int set_curr_pre_handler(struct kprobe *p, struct pt_regs *regs)
{
	long ua = (long)regs->regs[1];

	/* Respect an explicit stop (0); otherwise force the configured mA. */
	if (!enable || force_ma <= 0 || ua <= 0 || ua >= 20000000)
		return 0;

	regs->regs[1] = (unsigned long)((long)clamp_int(force_ma, 0, 21500) * 1000);
	if (verbose)
		pr_info("vcut_lower: set_curr %ld -> %d mA\n",
			ua / 1000, force_ma);
	return 0;
}

static struct kprobe kp_setcurr = {
	.symbol_name = "charger_dev_set_charging_current",
	.pre_handler = set_curr_pre_handler,
};

/* ---- fg_get_property: real SOC + shutdown floor --------------------- */

struct fg_args {
	unsigned long psy;
	int psp;
	void *val;
};

static int fg_entry_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct fg_args *a = (struct fg_args *)ri->data;

	a->psy = regs->regs[0];
	a->psp = (int)regs->regs[1];
	a->val = (void *)regs->regs[2];
	return 0;
}

static int fg_ret_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct fg_args *a = (struct fg_args *)ri->data;
	int ret = (int)(long)regs->regs[0];
	int cap = 0;

	if (ret != 0)
		return 0;
	/*
	 * 伪装循环次数：只改读取结果，不写驱动缓存。
	 * 这样 fake_cycle=-1 的下一帧就是真实循环数，不必等电量计巡检。
	 */
	if (a->psp == XAGA_PROP_CYCLE_COUNT) {
		int fc = READ_ONCE(fake_cycle);

		WRITE_ONCE(t_fg_cyc_hits, READ_ONCE(t_fg_cyc_hits) + 1);
		if (a->val && enable && fc >= 0) {
			*(volatile int *)a->val = fc;
			WRITE_ONCE(t_fg_cycle, fc);
		}
		return 0;
	}
	if (a->psp != XAGA_PROP_CAPACITY || !a->val)
		return 0;
	if (copy_from_kernel_nofault(&cap, a->val, sizeof(int)))
		return 0;

	WRITE_ONCE(t_hits, READ_ONCE(t_hits) + 1);

	/*
	 * At full charge the gauge sets FC and reports 100, while rm/fcc can
	 * still read 98~99% (FCC learning / taper compensation).  Trust the
	 * gauge in that state instead of dragging a full battery back to 98.
	 * Below 100 the real-SOC takeover still corrects the inflated reading.
	 */
	if (enable && soc_ctl && cap < 100) {
		int soc = READ_ONCE(t_soc_real);

		/*
		 * Plan B: when coul_ctl is on and the integrator has a base,
		 * the integrated SOC replaces the gauge's rm/fcc reading --
		 * but only within what the pack voltage allows.  Integration
		 * can lag (a suspended gap is dropped, never guessed), so the
		 * measured voltage stays authoritative at the bottom end:
		 * sitting at 30% while the pack is at 3.5V would be worse
		 * than the number it replaces.
		 */
		if (coul_ctl > 0) {
			int cs = READ_ONCE(t_coul_soc);

			if (cs >= 0) {
				int mv = READ_ONCE(t_mv);
				int floor_mv = clamp_int(READ_ONCE(vcut_delay), 2500, 3400);

				/*
				 * Voltage sanity floor, deliberately loose.  A full
				 * 100%->shutdown run on a 6000 mAh ground truth landed
				 * within 0.4% of true_mah, so the integration is the
				 * primary source; this only catches a runaway.  The
				 * limits below come from that run's own calibration:
				 *   3450mV -> 11%, 3350mV -> 6%, 3250mV -> 2%.
				 * They sit one band above the measured values so a
				 * correct integration is never flattened.
				 */
				if (mv > 0 && mv < 3250 && cs > 3)
					cs = 3;
				else if (mv > 0 && mv < 3350 && cs > 9)
					cs = 9;
				else if (mv > 0 && mv < 3450 && cs > 15)
					cs = 15;

				/*
				 * Hand MIUI its 2->1 falling edge exactly at the
				 * user's shutdown voltage.
				 *
				 * ph.v.f0() calls ph.v.g0() only when level or status
				 * CHANGES, and g0() is what VcutHook rewrites.  The
				 * old code pinned capacity at 1 for the whole tail,
				 * so level never changed, g0() was never called, the
				 * 30s countdown never armed, and the phone ran all
				 * the way to the PMIC's ~2.9V cutoff instead of
				 * stopping at vcut_delay.
				 *
				 * Reporting the integrated SOC while above the floor
				 * and then 1 throttles that: below floor the edge is
				 * delivered at once.  The cs<=1 clamp to 2 keeps the
				 * edge in reserve when the integration reaches the
				 * last percent before the voltage does -- otherwise
				 * the 2->1 step would be spent early and g0() would
				 * not be called again.
				 */
				if (mv > 0 && floor_mv > 0 && mv < floor_mv)
					soc = 1;
				else if (cs <= 1)
					soc = 2;
				else
					soc = cs;
			}
		}

		/*
		 * Never let the framework see capacity 0.  Android BatteryService
		 * calls shutdownIfNoPowerLocked() -> sys.powerctl=shutdown,battery
		 * as soon as mBatteryLevel reaches 0 while not charging, which is
		 * a DIFFERENT path from MIUI PowerSaveService's 30s countdown that
		 * VcutHook guards.  The gauge reports rm=0 near its stock cutoff
		 * (~3.6V) even though our shutdown floor is vcut_delay (3000mV),
		 * so trusting soc=0 there powers the phone off far too early.
		 * Clamp to 1 (charging included, per user choice): BatteryService
		 * only shuts down at 0, and PowerSaveService still gets its forced
		 * level=1 falling edge from VcutHook at the real floor.
		 */
		if (soc <= 0)
			soc = 1;

		if (soc >= 0 && soc <= 100 && soc != cap) {
			*(volatile int *)a->val = soc;
			cap = soc;
		}
	}

	/*
	 * Only the 0->1 clamp above is applied; no wider spoofing.  Earlier
	 * builds clamped a gauge SOC of 0 to 3% (and released 1% at
	 * vcut_delay) to dodge MIUI PowerSaveService's 30s countdown.  That
	 * only covered the cap==0 frame and still let the 2->1 falling edge
	 * through, so VcutHook (framework side) now owns the 30s countdown by
	 * forcing level=1 only at the real shutdown floor.  The 0->1 clamp
	 * here exists solely to stop Android BatteryService's immediate
	 * shutdown,battery; it cannot create or hide that falling edge.
	 */
	if (cap > 0)
		WRITE_ONCE(t_vbatt_empty, 0);

	WRITE_ONCE(t_disp, cap * 100);
	WRITE_ONCE(t_vc_hits, READ_ONCE(t_vc_hits) + 1);
	return 0;
}

static struct kretprobe krp_fg = {
	.kp.symbol_name = "fg_get_property",
	.entry_handler = fg_entry_handler,
	.handler = fg_ret_handler,
	.data_size = sizeof(struct fg_args),
	.maxactive = 32,
};

/* ---- 1s sampler ----------------------------------------------------- */

static void mon_work_fn(struct work_struct *w);
static DECLARE_DELAYED_WORK(mon_work, mon_work_fn);

/* ---- shutdown-delay uevent injection -------------------------------- */
/*
 * bq28z610.c only calls power_supply_changed() when shutdown_delay flips:
 *
 *     if (last_shutdown_delay != bq->shutdown_delay || val->intval == 0)
 *
 * so the single POWER_SUPPLY_SHUTDOWN_DELAY=1 the gauge emits at its own
 * 3310mV threshold (cell_voltage[2], not voltage_now) is all MIUI ever
 * sees.  VcutHook swallows that one event, and because last_shutdown ==
 * shutdown from then on, the kernel goes permanently silent -- the 30s
 * countdown never appears at the user's vcut_delay.
 *
 * Re-emit it from the 1s sampler so the trigger follows vcut_delay.
 * MIUI's BatteryUEventObserver matches on the KEY inside the uevent
 * string, not on the kobject it came from:
 *   MiuiBatteryServiceImpl.java:831  SHUTDOWN_DELAY_EVENT = "POWER_SUPPLY_SHUTDOWN_DELAY"
 *   MiuiBatteryServiceImpl.java:943  mUEventObserver.startObserving(SHUTDOWN_DELAY_EVENT)
 *   MiuiBatteryServiceImpl.java:1184 compare with mLastShutdownDelay, then sendMessage(7, v)
 * so any kobj reaches it.
 *
 * Two events are needed, not one: onUEvent drops a value equal to
 * mLastShutdownDelay, and the kernel already delivered 1 once.  Sending
 * 0 first resets MIUI's latch so the following 1 is a real edge.
 */
static int shut_state;		/* 0=idle, 1=sent 0, 2=sent 0 then 1, 3=skipped */

/*
 * 倒计时一旦 fire，不许被毫伏级抖动打断。
 *
 * 旧逻辑：mv_now >= floor 就立刻 release(0)。3050 这条线正好压在
 * voltage_now 的噪声上（实测 1 秒内 3044 <-> 3056 反复穿越），于是
 * fire(1) 发出 1 秒后就被 release(0) 撤掉，框架侧倒计时起不来；
 * 更糟的是 shut_state 已到 2，之后不再重发 1，电压真掉下去时反而静默。
 *
 * 现在：回升必须连续 shut_release_secs 秒都 >= floor + shut_hyst_mv 才算
 * 真的回升。落在 [floor, floor+hyst) 的滞回带里既不算回升也不算新的跌落，
 * state==2 时保持倒计时不动。
 */
static int shut_hyst_mv = 30;
module_param(shut_hyst_mv, int, 0644);
static int shut_release_secs = 5;
module_param(shut_release_secs, int, 0644);
static int shut_above_cnt;	/* 连续高于 floor+hyst 的秒数 */

/* bms_psy is assigned by the sampler below; declare it here because the
 * uevent helper is defined before the sampler's globals. */
static struct power_supply *bms_psy;

static void shut_ue(int val)
{
	char buf[40];
	char *envp[2];

	if (!bms_psy)
		return;
	snprintf(buf, sizeof(buf), "POWER_SUPPLY_SHUTDOWN_DELAY=%d", val);
	envp[0] = buf;
	envp[1] = NULL;
	WRITE_ONCE(t_shut_ue, val);
	kobject_uevent_env(&bms_psy->dev.kobj, KOBJ_CHANGE, envp);
}

/*
 * Called once a second.  Below the floor: pulse 0 then 1 across two
 * samples (the 1s gap is invisible next to a 30s countdown) so MIUI sees
 * a fresh edge no matter what it latched the last time.  Above the floor
 * or on charger: send a single 0 so a pending countdown is dropped, then
 * go idle so plugging back in re-arms cleanly.
 */
static void shut_tick(int mv_now, int floor_mv, int online, int status)
{
	if (!enable || !soc_ctl || floor_mv <= 0 || mv_now <= 0)
		return;

	if (online || status == POWER_SUPPLY_STATUS_CHARGING) {
		if (shut_state) {
			/* 倒计时可能正在跑：插上充电器必须把那一轮撤掉 */
			if (shut_state == 2) {
				shut_ue(0);
				pr_info("vcut_lower: shut cancel by charger at %dmV\n", mv_now);
			}
			shut_state = 0;
			WRITE_ONCE(t_shut_sent, 0);
		}
		shut_above_cnt = 0;
		/* 插上充电器 = 新一轮开始，"临时取消"不再延续 */
		if (READ_ONCE(shut_skip)) {
			WRITE_ONCE(shut_skip, 0);
			WRITE_ONCE(t_shut_skip, 0);
		}
		return;
	}

	WRITE_ONCE(t_shut_mv, mv_now);
	WRITE_ONCE(t_shut_skip, READ_ONCE(shut_skip) ? 1 : 0);

	if (mv_now >= floor_mv + READ_ONCE(shut_hyst_mv)) {
		/* 真的回到闸以上（带滞回）：倒计时可以撤，闩锁自动解除 */
		if (READ_ONCE(shut_skip)) {
			WRITE_ONCE(shut_skip, 0);
			WRITE_ONCE(t_shut_skip, 0);
		}
		if (shut_state == 2) {
			/* 倒计时在跑：连续 shut_release_secs 秒确认回升才撤 */
			if (++shut_above_cnt >= READ_ONCE(shut_release_secs)) {
				shut_above_cnt = 0;
				shut_state = 0;
				WRITE_ONCE(t_shut_sent, 0);
				shut_ue(0);
				pr_info("vcut_lower: shut release %dmV >= %dmV+hyst (stable)\n",
					mv_now, floor_mv);
			}
			return;
		}
		if (shut_state) {
			shut_state = 0;
			WRITE_ONCE(t_shut_sent, 0);
			shut_above_cnt = 0;
			pr_info("vcut_lower: shut release %dmV >= %dmV\n",
				mv_now, floor_mv);
		}
		return;
	}

	/*
	 * 滞回带 [floor, floor+hyst)：既不算真回升，也不算新的跌落。
	 * state==2 时保持倒计时；state==1 时等它继续掉；state==0 不在这里 arm，
	 * 免得好好的时候被噪声带去发 0。
	 */
	if (mv_now >= floor_mv) {
		shut_above_cnt = 0;
		return;
	}
	shut_above_cnt = 0;

	/*
	 * 用户按了"临时取消"：
	 *   - state 2（倒计时已经在跑）→ 补发一次 0 把它撤掉，然后锁到 3，
	 *     本轮不再发 1；
	 *   - 其它状态直接锁到 3，一开始就不给倒计时。
	 * state 3 是本轮终止态，只有回到闸以上或插充电器才回到 0。
	 */
	if (READ_ONCE(shut_skip)) {
		if (shut_state != 3) {
			if (shut_state == 2)
				shut_ue(0);
			shut_state = 3;
			WRITE_ONCE(t_shut_sent, 0);
			pr_info("vcut_lower: shut skipped by user at %dmV < %dmV\n",
				mv_now, floor_mv);
		}
		return;
	}

	if (shut_state == 3)
		return;

	switch (shut_state) {
	case 0:
		shut_ue(0);
		shut_state = 1;
		pr_info("vcut_lower: shut arm %dmV < %dmV\n", mv_now, floor_mv);
		break;
	case 1:
		shut_ue(1);
		shut_state = 2;
		WRITE_ONCE(t_shut_sent, 1);
		pr_info("vcut_lower: shut fire %dmV < %dmV\n", mv_now, floor_mv);
		break;
	default:
		break;
	}
}

static struct power_supply *batt_psy;

static int ps_get_int(struct power_supply *psy, enum power_supply_property p,
		      int *out)
{
	union power_supply_propval v;
	int rc;

	if (!psy)
		return -ENODEV;
	memset(&v, 0, sizeof(v));
	rc = power_supply_get_property(psy, p, &v);
	if (rc)
		return rc;
	*out = v.intval;
	return 0;
}

static void mon_work_fn(struct work_struct *w)
{
	union power_supply_propval pf, pc;
	int full_ua = 0, rm_ua = 0;
	int mv = 0, ma = 0, temp = 0, cyc = 0, cap = 0, status = 0;
	int online = 0, floor, soc = 0;
	struct power_supply *usb;

	if (!bms_psy)
		bms_psy = power_supply_get_by_name("bms");
	if (!batt_psy)
		batt_psy = power_supply_get_by_name("battery");

	if (bms_psy) {
		memset(&pf, 0, sizeof(pf));
		memset(&pc, 0, sizeof(pc));
		if (!power_supply_get_property(bms_psy,
				XAGA_PROP_CHARGE_FULL, &pf) &&
		    !power_supply_get_property(bms_psy,
				XAGA_PROP_CHARGE_COUNTER, &pc)) {
			full_ua = pf.intval;
			rm_ua = pc.intval;
		}
		ps_get_int(bms_psy, POWER_SUPPLY_PROP_VOLTAGE_NOW, &mv);
		ps_get_int(bms_psy, POWER_SUPPLY_PROP_CURRENT_NOW, &ma);
		ps_get_int(bms_psy, POWER_SUPPLY_PROP_TEMP, &temp);
		ps_get_int(bms_psy, POWER_SUPPLY_PROP_CYCLE_COUNT, &cyc);
		ps_get_int(bms_psy, POWER_SUPPLY_PROP_CAPACITY, &cap);
	}
	if (batt_psy)
		ps_get_int(batt_psy, POWER_SUPPLY_PROP_STATUS, &status);

	usb = power_supply_get_by_name("usb");
	if (usb) {
		ps_get_int(usb, POWER_SUPPLY_PROP_ONLINE, &online);
		power_supply_put(usb);
	}

	if (fcc_mah > 0)
		full_ua = fcc_mah * 1000;
	if (full_ua > 0 && rm_ua >= 0) {
		long long num = (long long)rm_ua + (long long)qbot_mah * 1000;
		long long den = (long long)full_ua + (long long)qbot_mah * 1000;
		int raw;

		/* round instead of truncate: rm/fcc = 98.98% -> 99, not 98 */
		soc = (int)((num * 100 + den / 2) / den);
		raw = (int)((long long)rm_ua * 10000 / full_ua);
		WRITE_ONCE(t_soc_real, clamp_int(soc, 0, 100));
		WRITE_ONCE(t_raw_soc, clamp_int(raw, 0, 10000));
		WRITE_ONCE(t_fcc, full_ua / 1000);
		WRITE_ONCE(t_rm, rm_ua / 1000);
	} else {
		WRITE_ONCE(t_soc_real, -1);
	}

	WRITE_ONCE(t_mv, mv / 1000);
	WRITE_ONCE(t_mean_volt, mv / 1000);
	WRITE_ONCE(t_vpack, mv / 1000);
	WRITE_ONCE(t_current, ma);
	WRITE_ONCE(t_temp, temp);
	WRITE_ONCE(t_soc, cap);
	WRITE_ONCE(t_cycle, cyc);
	WRITE_ONCE(t_fg_cycle, cyc);
	WRITE_ONCE(fg_cyc_armed, fake_fg_cycle >= 0 ? 1 : 0);
	WRITE_ONCE(vc_armed, 1);

	/*
	 * Coulomb integration (plan B).
	 *
	 * Runs every second off the same power_supply reads the gauge
	 * takeover already does, so it costs nothing extra.  Two re-base
	 * points keep it honest across plug/unplug:
	 *
	 *   full charge  -> base = 100%, accumulator cleared
	 *   unplugged    -> base = whatever SOC the gauge shows right then
	 *
	 * Between those, charge is folded with sign (discharging positive,
	 * charging negative) so a mid-run top-up walks the number back up.
	 * Samples further apart than 60s are dropped rather than folded: the
	 * work cannot run while the phone is suspended, and crediting a
	 * 40-minute gap to a single 1s current sample would be far worse
	 * than admitting the gap.
	 */
	{
		u64 now_ms = ktime_to_ms(ktime_get());
		bool charging = online ||
			status == POWER_SUPPLY_STATUS_CHARGING;
		bool full = status == POWER_SUPPLY_STATUS_FULL ||
			(cap >= 100 && online);

		if (full) {
			if (!coul_full_latch) {
				coul_full_latch = true;
				coul_arm(100, ma, mv / 1000);
			}
			coul_last_ms = now_ms;
		} else {
			coul_full_latch = false;
			if (coul_armed && charging)
				coul_charged_since_arm = true;
			if (!coul_armed && !charging) {
				int arm_soc = READ_ONCE(t_soc_real);

				if (arm_soc < 0)
					arm_soc = cap;
				/*
				 * Do not arm on the first sample after a (re)load:
				 * power_supply can still hand back 0/1 there, and a
				 * base of 1% would pin the whole run to the wrong
				 * number.  A genuinely flat pack (<2%) does not need
				 * integration anyway -- it is about to shut down.
				 */
				if (arm_soc >= 2 && mv > 3000000 && mv < 4600000)
					coul_arm(arm_soc, ma, mv / 1000);
			}
		}

		if (coul_armed) {
			if (coul_last_ms)
				coul_fold(ma, now_ms - coul_last_ms);
			coul_last_ms = now_ms;

			WRITE_ONCE(t_coul_ma, ma / 1000);
			WRITE_ONCE(t_coul_mah, (int)(coul_uah / 1000));
			WRITE_ONCE(t_coul_soc, coul_soc_now());
			WRITE_ONCE(t_coul_state, 2);

			/*
			 * End of a clean full->empty run: remember what actually
			 * came out of the pack.  coul_uah counts both directions,
			 * so any mid-run top-up corrupts the figure -- that is why
			 * coul_charged_since_arm voids the measurement outright.
			 */
			if (coul_learn_pending && !coul_charged_since_arm) {
				int s_now = READ_ONCE(t_coul_soc);
				int fl = clamp_int(READ_ONCE(vcut_delay), 2500, 3400);

				if (s_now >= 0 && (s_now <= 1 ||
					  (mv > 0 && mv / 1000 < fl))) {
					int m = (int)(coul_uah / 1000);

					if (m >= 3000 && m <= 8000 &&
						    temp >= 150 && temp <= 400) {
						coul_learn_measured =
							(true_mah * 3 + m) / 4;
						WRITE_ONCE(t_learn_mah,
							   coul_learn_measured);
						pr_info("vcut_lower: capacity measured %d mAh temp %d -> next %d\n",
							m, temp, coul_learn_measured);
					}
					coul_learn_pending = 0;
				}
			}

			/*
			 * Resting-voltage re-base.  Daily use almost never gives a clean
			 * full->empty run, so true_mah stays a slow learner; SOC drift, on
			 * the other hand, can be corrected every time the pack rests,
			 * because OCV->SOC is a chemistry curve independent of true_mah.
			 * Reconcile only on a real disagreement (>8%) and at most once an
			 * hour, so the percentage does not wobble in the user's face.
			 */
			if (!charging && ma > -100000 && ma < 100000)
				coul_quiet_sec++;
			else
				coul_quiet_sec = 0;

			if (coul_quiet_sec >= 300) {
				u64 now2 = ktime_to_ms(ktime_get());
				int ocv = ocv_to_soc(mv / 1000);
				int cur = READ_ONCE(t_coul_soc);

				if (ocv >= 0 && cur >= 0 &&
					(ocv > cur ? ocv - cur : cur - ocv) > 8 &&
					now2 - coul_last_calib_ms > 3600000) {
					s64 full = (s64)true_mah * 1000;

					if (full > 0) {
						coul_base_soc = clamp_int(
							ocv + (int)(coul_uah * 100 / full), 0, 100);
						coul_last_calib_ms = now2;
						pr_info("vcut_lower: coul rebase %d -> %d ocv %dmV\n",
							cur, ocv, mv / 1000);
					}
				}
				coul_quiet_sec = 240;
			}
		}
	}

	floor = clamp_int(vcut_delay, 2500, 3400);
	WRITE_ONCE(t_cross_delay, floor);
	shut_tick(mv / 1000, floor, online, status);
	WRITE_ONCE(t_orig_delay, 3400);
	if (!online) {
		if (!cross_active && mv / 1000 <= 3400 && rm_ua > 0) {
			cross_active = true;
			cross_rm_mah = rm_ua / 1000;
			cross_min_mv = mv / 1000;
			WRITE_ONCE(t_cross_seq, READ_ONCE(t_cross_seq) + 1);
			WRITE_ONCE(t_cross_rm, cross_rm_mah);
			WRITE_ONCE(t_cross_mv, mv / 1000);
			WRITE_ONCE(t_cross_ma, ma);
			WRITE_ONCE(t_cross_temp, temp);
			WRITE_ONCE(t_cross_stock, 3400);
		}
		if (cross_active) {
			int below = cross_rm_mah - rm_ua / 1000;

			WRITE_ONCE(t_below_mah, below > 0 ? below : 0);
			if (mv / 1000 < cross_min_mv)
				cross_min_mv = mv / 1000;
			WRITE_ONCE(t_below_min_mv, cross_min_mv);
		}
	} else if (mv / 1000 > 3600) {
		cross_active = false;
	}

	WRITE_ONCE(t_vbatt_empty,
		   (!online && mv / 1000 <= floor) ? 1 : 0);
	WRITE_ONCE(t_off_src, 0);
	WRITE_ONCE(t_failsafe, 0);
	WRITE_ONCE(t_no_kick, 0);
	WRITE_ONCE(t_gate_ok, 1);
	WRITE_ONCE(t_cyc_ok, 1);

	if (verbose > 1)
		pr_info("vcut_lower: vbat=%dmV soc=%d real=%d cap=%d cur=%d t=%d cyc=%d online=%d\n",
			mv / 1000, cap, soc, cap, ma, temp, cyc, online);

	schedule_delayed_work(&mon_work, msecs_to_jiffies(1000));
}

/* ---- init/exit ------------------------------------------------------- */

static int __init vcut_lower_init(void)
{
	int ret;

	ret = register_kprobe(&kp_vote);
	if (ret < 0) {
		pr_err("vcut_lower: register vote failed %d\n", ret);
		return ret;
	}
	ret = register_kprobe(&kp_setcv);
	if (ret < 0) {
		pr_err("vcut_lower: register set_cv failed %d\n", ret);
		goto err_vote;
	}
	ret = register_kprobe(&kp_setcurr);
	if (ret < 0) {
		pr_err("vcut_lower: register set_curr failed %d\n", ret);
		goto err_setcv;
	}
	ret = register_kretprobe(&krp_eff);
	if (ret < 0) {
		pr_err("vcut_lower: register get_effective_result failed %d\n",
		       ret);
		goto err_setcurr;
	}
	ret = register_kretprobe(&krp_eff_locked);
	if (ret < 0) {
		pr_err("vcut_lower: register get_effective_result_locked failed %d\n",
		       ret);
		goto err_eff;
	}
	ret = register_kretprobe(&krp_fg);
	if (ret < 0) {
		pr_err("vcut_lower: register fg failed %d\n", ret);
		goto err_eff_locked;
	}

	WRITE_ONCE(armed, 1);
	schedule_delayed_work(&mon_work, msecs_to_jiffies(500));
	pr_info("vcut_lower: loaded xaga backend fv=%d fcc=%d qbot=%d delay=%d force=%d\n",
		fv_target_mv, fcc_mah, qbot_mah, vcut_delay, force_ma);
	return 0;

err_eff_locked:
	unregister_kretprobe(&krp_eff_locked);
err_eff:
	unregister_kretprobe(&krp_eff);
err_setcurr:
	unregister_kprobe(&kp_setcurr);
err_setcv:
	unregister_kprobe(&kp_setcv);
err_vote:
	unregister_kprobe(&kp_vote);
	return ret;
}

static void __exit vcut_lower_exit(void)
{
	force_ma = 0;
	cancel_delayed_work_sync(&mon_work);
	unregister_kretprobe(&krp_fg);
	unregister_kretprobe(&krp_eff_locked);
	unregister_kretprobe(&krp_eff);
	unregister_kprobe(&kp_setcurr);
	unregister_kprobe(&kp_setcv);
	unregister_kprobe(&kp_vote);
	if (bms_psy) {
		power_supply_put(bms_psy);
		bms_psy = NULL;
	}
	if (batt_psy) {
		power_supply_put(batt_psy);
		batt_psy = NULL;
	}
	WRITE_ONCE(armed, 0);
	pr_info("vcut_lower: unloaded\n");
}

module_init(vcut_lower_init);
module_exit(vcut_lower_exit);
