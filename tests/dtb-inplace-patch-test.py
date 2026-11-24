#!/usr/bin/env python3
"""Host tests for the byte-preserving payload DTB patcher.

The A-slot handover stub pokes the kshim-append reg through a compile-time byte
offset inside the appended DTB, so every edit has to leave totalsize and all
struct offsets exactly where the factory image put them. These tests pin that
invariant, plus the two refusal paths.
"""
import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, '..', 'devices', 'lenovo-tb320fc', 'boot', 'a-series',
                    'bootimg', 'patch_dtb_inplace.py')

SRC = """
/dts-v1/;

/ {
	filler {
		blob = "%s";
	};

	soc {
		#address-cells = <1>;
		#size-cells = <1>;

		thermal-sensor@c263000 {
			status = "disabled";
			compatible = "qcom,sm8450-tsens", "qcom,tsens-v2";
			reg = <0xc263000 0x1000>;
			#thermal-sensor-cells = <1>;
		};
		thermal-sensor@c265000 {
			compatible = "qcom,sm8450-tsens", "qcom,tsens-v2";
			reg = <0xc265000 0x1000>;
			#thermal-sensor-cells = <1>;
		};
		marker-after@1234 {
			status = "ok";
			reg = <0x1234 0x10>;
		};
	};
};
""" % ('x' * 6000)

FAILS = []
CHECKS = [0]


def check(label, condition, detail=''):
    CHECKS[0] += 1
    if condition:
        print('OK   %s' % label)
    else:
        FAILS.append(label)
        print('FAIL %s %s' % (label, detail))


def run(args):
    return subprocess.run([sys.executable, TOOL] + args, capture_output=True, text=True)


def offsets(buf):
    spec = importlib.util.spec_from_file_location('patcher', TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, module.walk(buf)


def main():
    if not os.path.exists(TOOL):
        print('TOOL_MISSING %s' % TOOL)
        return 1
    with tempfile.TemporaryDirectory() as work:
        dts = os.path.join(work, 'base.dts')
        dtb = os.path.join(work, 'base.dtb')
        with open(dts, 'w') as handle:
            handle.write(SRC)
        dtc = subprocess.run(['dtc', '-I', 'dts', '-O', 'dtb', '-o', dtb, dts],
                                     capture_output=True, text=True)
        check('dtc compiles the fixture', dtc.returncode == 0, dtc.stderr)
        blob = open(dtb, 'rb').read()

        # Emulate the container: the appended DTB sits on a page boundary.
        image = os.path.join(work, 'boot_a-test.img')
        head = b'\0' * 4096 + b'\xa5' * 8192
        tail = b'\x5a' * 4096
        with open(image, 'wb') as handle:
            handle.write(head + blob + tail)
        base = len(head)

        out = os.path.join(work, 'boot_a-patched.img')
        result = run([image, out, 'thermal-sensor@c263000=okay'])
        check('patch exits 0', result.returncode == 0, result.stdout + result.stderr)
        if result.returncode != 0:
            print(result.stdout)
            return 1
        report = json.loads(result.stdout)
        check('single dtb candidate', report['dtb_off'] == base and report['dtb_size'] == len(blob),
              str(report))
        check('all diffs inside the dtb', report['outside_dtb_diffs'] == 0, str(report))
        check('only the status value moved', report['total_diff_bytes'] == 8,
              str(report['total_diff_bytes']))

        patched = open(out, 'rb').read()
        check('image length unchanged', len(patched) == len(head + blob + tail))
        check('padding untouched', patched[:base] == head and patched[base + len(blob):] == tail)
        new_blob = patched[base:base + len(blob)]
        check('dtb totalsize unchanged', struct.unpack('>I', new_blob[4:8])[0] == len(blob))

        module, walk_after = offsets(new_blob)
        _, walk_before = offsets(blob)
        check('struct walk identical (offsets pinned)', walk_before == walk_after)
        check('walk still parses after patch', len(walk_after) == len(walk_before))

        status_off = [e[2] for e in walk_after if e[0] == 'prop' and e[1] == 'status']
        values = []
        for off in status_off:
            length = [e[3] for e in walk_after if e[0] == 'prop' and e[1] == 'status' and e[2] == off][0]
            values.append(new_blob[off:off + length])
        check('status property length untouched', all(len(v) == 9 or len(v) == 3 for v in values),
              str([len(v) for v in values]))
        check('target reads okay as a C string', values[0].split(b'\0')[0] == b'okay', str(values))
        marker = [v for v in values if v.split(b'\0')[0] in (b'ok', b'okay')][-1]
        check('later node untouched', marker == b'ok\0', str(marker))
        check('untargeted node without status stays absent',
              b'disabled' not in new_blob, 'a second disabled value leaked')

        # refusal: the node has no status property at all
        missing = run([image, os.path.join(work, 'x.img'), 'thermal-sensor@c265000=okay'])
        check('missing status refuses', missing.returncode == 1 and 'PROPS_FOUND' in missing.stdout,
              missing.stdout + missing.stderr)
        check('refusal writes nothing', not os.path.exists(os.path.join(work, 'x.img')))

        # refusal: the new value does not fit the old property length
        tight = run([image, os.path.join(work, 'y.img'), 'marker-after@1234=disabled'])
        check('no room refuses', tight.returncode == 1 and 'NO_ROOM' in tight.stdout,
              tight.stdout + tight.stderr)

        # refusal: more than one walkable DTB is ambiguous
        dup = os.path.join(work, 'boot_a-dup.img')
        with open(dup, 'wb') as handle:
            handle.write(head + blob + tail + blob)
        ambiguous = run([dup, os.path.join(work, 'z.img'), 'thermal-sensor@c263000=okay'])
        check('two dtb candidates refuse', ambiguous.returncode == 1
              and 'DTB_CANDIDATES 2' in ambiguous.stdout, ambiguous.stdout + ambiguous.stderr)

    if FAILS:
        print('DTB_PATCH_FAILED %s' % ' '.join(FAILS))
        return 1
    print('DTB_PATCH_OK %d checks' % CHECKS[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
