# quakepush/iller.js'yi kayıt defterinden üretir: il merkezi ve il yarıçapı
# (merkezden en uzak ilçe merkezine uzaklık + 25 km pay).
#   python3 tool/quakepush_iller.py > quakepush/iller.js
import json, math

def km(a, b, c, d):
    r = 6371.0
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = p2 - p1, math.radians(d - b)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))

g = json.load(open('registry/geo.json'))
rows = []
for il in g['iller']:
    far = max([km(il['lat'], il['lon'], d['lat'], d['lon']) for d in il['ilceler'] if d.get('lat')] or [0])
    rows.append(f"  [{il['plaka']}, {il['lat']:.4f}, {il['lon']:.4f}, {round(far + 25)}], // {il['ad']}")
print('// tool/quakepush_iller.py ile üretildi: [plaka, enlem, boylam, yarıçap km]')
print('export const ILLER = [')
print('\n'.join(rows))
print('];')
