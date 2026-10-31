#!/usr/bin/env python3
import contextlib,importlib.util,importlib.machinery,io,json,os,struct,tempfile,unittest,uuid,zlib
from pathlib import Path
from unittest.mock import patch
root=Path(__file__).resolve().parents[1]
loader=importlib.machinery.SourceFileLoader('edl',str(root/'system_files/usr/bin/armada-reboot-edl'))
spec=importlib.util.spec_from_loader(loader.name,loader);edl=importlib.util.module_from_spec(spec);loader.exec_module(edl)
PART='11111111-2222-4333-8444-555555555555';INSTALL='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
def seal(b):struct.pack_into('<I',b,4092,zlib.crc32(b[:4092]))
def fixture(version=1):
    meta={'kind':'armada-board-recovery-image','schemaVersion':3,'imageBytes':edl.SIZE,'headerBytes':65536,'payloadOffset':65536,'compressedBytes':1024,'installationId':INSTALL,'configRegionOffset':edl.REGION_OFFSET,'configRegionBytes':65536,'configPartitionUuid':PART,'configBoardId':1}
    header=json.dumps(meta).encode().ljust(65536,b' ')
    d=bytearray(4096);d[:8]=b'KSCFGV3\0';struct.pack_into('<IIQQQII',d,8,1,4096,edl.SIZE,65536+1024,edl.REGION_OFFSET,65536,4096)
    d[48:64]=uuid.UUID(PART).bytes;d[64:80]=uuid.UUID(INSTALL).bytes;struct.pack_into('<III',d,80,4096,8192,1);seal(d)
    rec=bytearray(4096);rec[:8]=b'KSCFGR1\0';struct.pack_into('<IIQ',rec,8,version,4096,7);rec[24:40]=d[48:64];rec[40:56]=d[64:80]
    struct.pack_into('<5I',rec,56,0,2 if version==1 else 4,1,2 if version>=2 else 0,0);seal(rec)
    return header,bytes(d+rec+bytes(65536-8192))
class Tests(unittest.TestCase):
    def test_supported_board_soc_pairs(self):
        for compatible in (
            b'lenovo,elden\0qcom,sm8750\0',
            b'lenovo,baldur\0qcom,sm8850\0',
            b'lenovo,baldur\0qcom,kaanapali\0',
            b'lenovo,baldur\0qcom,sm8850\0qcom,kaanapali\0',
        ):
            with self.subTest(compatible=compatible):
                with patch.object(edl.Path,'read_bytes',side_effect=[compatible,b'']):
                    with self.assertRaisesRegex(edl.Refuse,'Installed launcher does not support Linux EDL requests'):
                        edl.device_context()
    def test_mismatched_board_soc_pairs_rejected(self):
        for compatible in (
            b'qcom,kaanapali\0',
            b'lenovo,elden\0qcom,kaanapali\0',
            b'lenovo,baldur\0qcom,sm8750\0',
            b'lenovo,elden\0lenovo,baldur\0qcom,sm8750\0qcom,kaanapali\0',
        ):
            with self.subTest(compatible=compatible):
                with patch.object(edl.Path,'read_bytes',return_value=compatible):
                    with self.assertRaisesRegex(edl.Refuse,'Unsupported board'):
                        edl.device_context()
    def makefile(self,version=1):
        f=tempfile.NamedTemporaryFile(dir=os.environ['TMPDIR']);f.truncate(edl.SIZE)
        h,r=fixture(version);os.pwrite(f.fileno(),h,0);os.pwrite(f.fileno(),b'backup payload stays',65536);os.pwrite(f.fileno(),r,edl.REGION_OFFSET)
        self.addCleanup(f.close);return f,h,r
    def test_old_records_and_bounded_roundtrip(self):
        for version in (1,2,3):
            with self.subTest(version=version):
                f,h,r=self.makefile(version);fd=f.fileno();store=edl.parse_store(h,r,PART,1);values=store['best']['values'][:4]
                real_write=os.pwrite;writes=[]
                def traced(fd,data,offset):writes.append((offset,len(data)));return real_write(fd,data,offset)
                with patch.object(edl.os,'pwrite',side_effect=traced):self.assertEqual(edl.set_request(fd,store,1),8)
                self.assertEqual(writes,[(edl.REGION_OFFSET+8192,4096)])
                self.assertEqual(os.pread(fd,65536,0),h);self.assertEqual(os.pread(fd,20,65536),b'backup payload stays')
                current=os.pread(fd,65536,edl.REGION_OFFSET);self.assertEqual(current[:8192],r[:8192]);self.assertEqual(current[12288:],r[12288:])
                armed=edl.parse_store(h,current,PART,1);self.assertEqual(armed['best']['values'],values+[1]);self.assertEqual(armed['best']['raw'][8],3)
                self.assertEqual(edl.set_request(fd,armed,0),9)
                clear=edl.parse_store(h,os.pread(fd,65536,edl.REGION_OFFSET),PART,1);self.assertEqual(clear['best']['values'],values+[0])
    def test_identity_and_reserved_rejected(self):
        h,r=fixture()
        for other,board in [(str(uuid.UUID(int=1)),1),(PART,2)]:
            with self.assertRaises(edl.Refuse):edl.parse_store(h,r,other,board)
        for offset in (0,4092,13000):
            bad=bytearray(r);bad[offset]^=1
            with self.assertRaises(edl.Refuse):edl.parse_store(h,bytes(bad),PART,1)
    def test_changed_store_and_partial_write(self):
        f,h,r=self.makefile();fd=f.fileno();store=edl.parse_store(h,r,PART,1)
        os.pwrite(fd,b'X',0)
        with self.assertRaises(edl.Refuse):edl.set_request(fd,store,1)
        os.pwrite(fd,h,0)
        with patch.object(edl.os,'pwrite',return_value=0),self.assertRaises(edl.Refuse):edl.set_request(fd,store,1)
        with patch.object(edl.os,'fsync',side_effect=OSError('flush failed')),self.assertRaises(OSError):edl.set_request(fd,store,1)
    def test_readback_failure_is_not_success(self):
        f,h,r=self.makefile();store=edl.parse_store(h,r,PART,1);real=os.pread
        def broken(fd,size,offset):return bytes(size) if size==4096 else real(fd,size,offset)
        with patch.object(edl.os,'pread',side_effect=broken),self.assertRaises(edl.Refuse):edl.set_request(f.fileno(),store,1)
    def test_cli_check_never_writes_or_reboots(self):
        f,h,r=self.makefile()
        with patch.object(edl,'device_context',return_value=(Path(f.name),PART,1,0)),patch.object(edl.os,'pwrite') as write,patch.object(edl.subprocess,'run') as reboot,contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(edl.main(['--check']),0);write.assert_not_called();reboot.assert_not_called()
    def test_cli_reboot_failure_cancels_request(self):
        f,h,r=self.makefile(2)
        class Failed:returncode=1
        with patch.object(edl,'device_context',return_value=(Path(f.name),PART,1,0)),patch.object(edl.subprocess,'run',return_value=Failed()) as reboot,contextlib.redirect_stdout(io.StringIO()),self.assertRaises(edl.Refuse):edl.main(['--reboot'])
        reboot.assert_called_once_with(['systemctl','reboot'],check=False)
        current=edl.parse_store(h,os.pread(f.fileno(),65536,edl.REGION_OFFSET),PART,1)
        self.assertEqual(current['best']['sequence'],9);self.assertEqual(current['best']['values'],[0,4,1,2,0])
    def test_bad_version_and_generation_conflict(self):
        h,r=fixture(3);bad=bytearray(r);rec=bytearray(bad[4096:8192]);struct.pack_into('<I',rec,72,2);seal(rec);bad[4096:8192]=rec
        with self.assertRaises(edl.Refuse):edl.parse_store(h,bytes(bad),PART,1)
        rec=bytearray(r[4096:8192]);struct.pack_into('<I',rec,64,0);seal(rec);bad=bytearray(r);bad[8192:12288]=rec
        with self.assertRaises(edl.Refuse):edl.parse_store(h,bytes(bad),PART,1)
if __name__=='__main__':unittest.main()
