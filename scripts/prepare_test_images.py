from hashlib import sha256
from pathlib import Path

from PIL import Image
from skimage import data


ROOT = Path(__file__).resolve().parents[1] / 'stages'
DESTINATIONS = (
    ROOT / 'stage0_2_fixedpoint_package/stage0_reference_64/data',
    ROOT / 'stage5d_single_pixel_gui/data/input_images',
    ROOT / 'stage6a_quality_opt_package/reference/stage0_reference_64/data',
)
EXAMPLES = {
    'cat64': (data.chelsea, '414e9383ba81a5ea5d02112dfdfc1625664979962da4bfb7575b18ec8f24a3d6'),
    'moon': (data.moon, 'b8448b042effa85bc5bc38ddcb0444b5110f6faa434c93f95a93ab8fb4395d36'),
    'rocket': (data.rocket, '583a2336c453d11cef78adb73c82d102b4e419e8d3075e708d7edc0e8558bcb5'),
    'text': (data.text, 'ff8246a806ff9e94ad6c29ea44c905a0af3815623f325e873b09ac03f84e7ed7'),
}


def main():
    for name, (load_image, expected_hash) in EXAMPLES.items():
        picture = Image.fromarray(load_image()).convert('L').resize((256, 256), Image.Resampling.LANCZOS)
        if name == 'cat64':
            picture = picture.resize((64, 64), Image.Resampling.LANCZOS)
        if sha256(picture.tobytes()).hexdigest() != expected_hash:
            raise ValueError(f'Pixel hash mismatch: {name}. Install requirements-examples.txt.')
        for directory in DESTINATIONS:
            directory.mkdir(parents=True, exist_ok=True)
            output = directory / f'{name}.png'
            if output.exists():
                with Image.open(output) as existing:
                    if existing.size != picture.size or sha256(existing.convert('L').tobytes()).hexdigest() != expected_hash:
                        raise FileExistsError(f'Will not overwrite a different image: {output}')
            else:
                picture.save(output)
        print(f'PASS: {name} matches archived grayscale pixels')


if __name__ == '__main__':
    main()
