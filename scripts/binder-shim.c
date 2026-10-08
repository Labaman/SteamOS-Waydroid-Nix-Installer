// SPDX-License-Identifier: GPL-2.0
/*
 * Shim for building the in-tree binder out of tree: resolves symbols the kernel does not
 * export to modules via kallsyms. Deployed by home.nix as shim.c/shim.h.
 */
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/sched.h>
#include <linux/ipc_namespace.h>
#include <linux/list_lru.h>
#include <linux/mm.h>
#include <linux/mmap_lock.h>
#include <linux/security.h>
#include <linux/task_work.h>
#include <linux/wait.h>
#include <linux/fdtable.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Android binder IPC (in-tree driver built out of tree)");

struct ipc_namespace *binder_shim_init_ipc_ns;

#define SHIM(ret, name, args, call)				\
	static typeof(&name) p_##name;				\
	ret name args { return p_##name call; }

SHIM(int, can_nice, (const struct task_struct *p, const int nice), (p, nice))
SHIM(bool, list_lru_del, (struct list_lru *lru, struct list_head *item, int nid,
			  struct mem_cgroup *memcg), (lru, item, nid, memcg))
/* Not exported on 6.18; the define is set by waydroid-setup from Module.symvers. */
#ifdef BINDER_SHIM_LIST_LRU_ADD
SHIM(bool, list_lru_add, (struct list_lru *lru, struct list_head *item, int nid,
			  struct mem_cgroup *memcg), (lru, item, nid, memcg))
#endif
SHIM(struct vm_area_struct *, lock_vma_under_rcu,
     (struct mm_struct *mm, unsigned long address), (mm, address))
SHIM(void, put_ipc_ns, (struct ipc_namespace *ns), (ns))
SHIM(int, security_binder_transaction, (const struct cred *from,
					const struct cred *to), (from, to))
SHIM(int, security_binder_transfer_binder, (const struct cred *from,
					    const struct cred *to), (from, to))
SHIM(int, security_binder_set_context_mgr, (const struct cred *mgr), (mgr))
SHIM(int, security_binder_transfer_file, (const struct cred *from,
					  const struct cred *to, const struct file *file),
     (from, to, file))
SHIM(struct file *, file_close_fd, (unsigned int fd), (fd))
SHIM(int, task_work_add, (struct task_struct *task, struct callback_head *twork,
			  enum task_work_notify_mode mode), (task, twork, mode))
SHIM(void, __wake_up_pollfree, (struct wait_queue_head *wq_head), (wq_head))
/* zap_vma_range on 7.x kernels, zap_page_range_single before (6.18).
 * The define is set by waydroid-setup from the kernel headers. */
#ifdef BINDER_HAVE_ZAP_VMA_RANGE
SHIM(void, zap_vma_range, (struct vm_area_struct *vma, unsigned long address,
			   unsigned long size), (vma, address, size))
#else
SHIM(void, zap_page_range_single, (struct vm_area_struct *vma, unsigned long address,
				   unsigned long size, struct zap_details *details),
     (vma, address, size, details))
#endif

static int __init binder_shim_init(void)
{
	struct kprobe kp = { .symbol_name = "kallsyms_lookup_name" };
	unsigned long (*lookup)(const char *);
	int ret;

	ret = register_kprobe(&kp);
	if (ret)
		return ret;
	lookup = (void *)kp.addr;
	unregister_kprobe(&kp);

#define RESOLVE(var, sym) do {						\
		var = (void *)lookup(sym);				\
		if (!var) {						\
			pr_err("binder: symbol %s not found\n", sym);	\
			return -ENOENT;					\
		}							\
	} while (0)
	RESOLVE(binder_shim_init_ipc_ns, "init_ipc_ns");
	RESOLVE(p_can_nice, "can_nice");
	RESOLVE(p_list_lru_del, "list_lru_del");
#ifdef BINDER_SHIM_LIST_LRU_ADD
	RESOLVE(p_list_lru_add, "list_lru_add");
#endif
	RESOLVE(p_lock_vma_under_rcu, "lock_vma_under_rcu");
	RESOLVE(p_put_ipc_ns, "put_ipc_ns");
	RESOLVE(p_security_binder_transaction, "security_binder_transaction");
	RESOLVE(p_security_binder_transfer_binder, "security_binder_transfer_binder");
	RESOLVE(p_security_binder_set_context_mgr, "security_binder_set_context_mgr");
	RESOLVE(p_security_binder_transfer_file, "security_binder_transfer_file");
	RESOLVE(p_file_close_fd, "file_close_fd");
	RESOLVE(p_task_work_add, "task_work_add");
	RESOLVE(p___wake_up_pollfree, "__wake_up_pollfree");
#ifdef BINDER_HAVE_ZAP_VMA_RANGE
	RESOLVE(p_zap_vma_range, "zap_vma_range");
#else
	RESOLVE(p_zap_page_range_single, "zap_page_range_single");
#endif
	return 0;
}

/* binder.c registers binder_init via device_initcall(); Kbuild renames its
 * init_module alias so the symbols can be resolved first. */
int binder_orig_init_module(void);

static int __init binder_shim_module_init(void)
{
	int ret = binder_shim_init();

	return ret ? ret : binder_orig_init_module();
}
module_init(binder_shim_module_init);
