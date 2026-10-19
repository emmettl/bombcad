import struct, sys, collections
def read_dbf(path):
    f = open(path, 'rb')
    head = f.read(32)
    n, hlen, rlen = struct.unpack('<IHH', head[4:12])
    fields = []
    while True:
        d = f.read(32)
        if d[0] == 0x0D: break
        name = d[:11].split(b'\0')[0].decode()
        fields.append((name, chr(d[11]), d[16]))
    f.seek(hlen)
    rows = []
    for _ in range(n):
        rec = f.read(rlen)
        if rec[0:1] == b'*': continue
        pos = 1; row = {}
        for name, t, size in fields:
            row[name] = rec[pos:pos+size].decode('latin-1').strip(); pos += size
        rows.append(row)
    return fields, rows
if __name__ == "__main__":
    fields, rows = read_dbf(sys.argv[1])
    print(fields)
    c = collections.Counter(r['Facade_dam'] for r in rows)
    for k, v in c.most_common(40): print(repr(k), v)
