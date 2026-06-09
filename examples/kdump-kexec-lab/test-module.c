#include <linux/init.h>
#include <linux/module.h>
#include <linux/version.h>

static int test_module_init(void)
{
	int *p = 1;
	printk("%d\n", *p);
	return 0;
}
static void test_module_exit(void)
{
	return;
}

module_init(test_module_init);
module_exit(test_module_exit);
MODULE_LICENSE("GPL");	/* added: modern modpost makes a missing license a hard
			   build error; the article's 4.9 kernel only tainted.
			   Appended at the END so the bug stays on line 8. */
