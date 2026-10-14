"""Generate Gate Log -> Rec.709 display LUT. Red changes fastest in .cube files."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
destination = root / "Gate/Resources/GateLog_to_Rec709.cube"
destination.parent.mkdir(parents=True, exist_ok=True)

def transform(code):
    linear = (2 ** (4 * code) - 1) / 15
    return 4.5 * linear if linear < 0.018 else 1.099 * linear ** 0.45 - 0.099

size = 33
lines = ['TITLE "Gate Log to Rec.709"', '# Input: custom Gate Log in Rec.709 primaries; output: Rec.709 OETF.',
         f'LUT_3D_SIZE {size}', 'DOMAIN_MIN 0.0 0.0 0.0', 'DOMAIN_MAX 1.0 1.0 1.0']
for blue in range(size):
    for green in range(size):
        for red in range(size):
            lines.append(" ".join(f"{transform(channel / (size - 1)):.9f}" for channel in (red, green, blue)))
destination.write_text("\n".join(lines) + "\n")
print(destination)
