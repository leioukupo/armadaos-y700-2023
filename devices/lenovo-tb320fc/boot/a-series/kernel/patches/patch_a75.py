import io

K = "/tmp/y700/kbuild/asphalt-linux"
p = K + "/drivers/spi/spi-geni-qcom.c"
s = io.open(p, encoding="utf-8", newline="").read()

old_block = "static bool force_pio;\n"
new_block = (
	"static bool force_pio = true;\n"
)
if "static bool force_pio = true;" in s:
	print("DEFAULT_ALREADY")
else:
	assert s.count(old_block) == 1, "force_pio declaration"
	s = s.replace(old_block, new_block, 1)

	old_note = " * two paths without reflashing.\n"
	new_note = (
		" * two paths without reflashing.  Default on: A74 proved that the first\n"
		" * 63 KiB firmware write of the Novatek touchscreen, run as SE DMA, resets the\n"
		" * whole SoC, and that the same transfer driven from the FIFO completes and\n"
		" * verifies (touch events after it).  Nothing here needs SE DMA speed.\n"
	)
	assert s.count(old_note) == 1, "force_pio comment tail"
	s = s.replace(old_note, new_note, 1)
	io.open(p, "w", encoding="utf-8", newline="").write(s)
	print("DEFAULT_PATCHED")
