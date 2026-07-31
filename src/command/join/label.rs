use glyph_brush_layout::{
    GlyphPositioner, HorizontalAlign, SectionGeometry, SectionText, VerticalAlign,
    ab_glyph::{Font, FontRef, PxScale, Rect, point},
};
use image::Pixel;
use std::sync::LazyLock;

const CANTARELL: &[u8] = include_bytes!("Cantarell-Regular.ttf");
static FONT: LazyLock<FontRef<'static>> = LazyLock::new(|| {
    FontRef::try_from_slice(CANTARELL).expect("embedded Cantarell font must be valid")
});

#[derive(Debug, Clone)]
pub struct Config {
    pub scale_percent: f32,
    pub margin_percent: f32,
    pub padding_percent: f32,
    pub background_opacity: f32,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            scale_percent: 0.06,
            margin_percent: 0.01,
            padding_percent: 0.01,
            background_opacity: 0.7,
        }
    }
}

pub fn draw(
    img: image::DynamicImage,
    label: &str,
    conf: &Config,
) -> anyhow::Result<image::DynamicImage> {
    if label.is_empty() {
        return Ok(img);
    }

    let (imgw, imgh) = (img.width() as f32, img.height() as f32);
    let min_dim = imgw.min(imgh);
    let font = &*FONT;
    let scale = PxScale::from(min_dim * conf.scale_percent);
    let margin = min_dim * conf.margin_percent;
    let pad = min_dim * conf.padding_percent;

    let layout = glyph_brush_layout::Layout::default_single_line()
        .v_align(VerticalAlign::Bottom)
        .h_align(HorizontalAlign::Right);
    let geometry = SectionGeometry {
        screen_position: (imgw - margin * 2.0, imgh - margin),
        bounds: (imgw, imgh),
    };

    let glyphs = layout.calculate_glyphs(
        &[&font],
        &geometry,
        &[SectionText {
            text: label,
            scale,
            ..<_>::default()
        }],
    );

    let mut rgba = img.into_rgba8();

    let outline_glyphs: Vec<_> = glyphs
        .into_iter()
        .filter_map(|g| font.outline_glyph(g.glyph))
        .collect();

    // label background
    if let Some(b) = outline_glyphs
        .iter()
        .map(|g| g.px_bounds())
        .fold(None, |b: Option<Rect>, next| {
            b.map(|b| {
                let min_x = b.min.x.min(next.min.x);
                let max_x = b.max.x.max(next.max.x);
                let min_y = b.min.y.min(next.min.y);
                let max_y = b.max.y.max(next.max.y);
                Rect {
                    min: point(min_x, min_y),
                    max: point(max_x, max_y),
                }
            })
            .or(Some(next))
        })
        .map(|mut b| {
            // cap the glyph bounds to the layout specified max bounds
            let Rect { min, max } = layout.bounds_rect(&geometry);
            b.min.x = b.min.x.max(min.x) - pad;
            b.min.y = b.min.y.max(min.y) - pad;
            b.max.x = b.max.x.min(max.x) + pad;
            b.max.y = b.max.y.min(max.y) + pad;
            b
        })
    {
        let max_x = (b.max.x.ceil() as u32).min(rgba.width() - 1);
        let min_x = b.min.x as u32;
        let max_y = (b.max.y.ceil() as u32).min(rgba.height() - 1);
        let min_y = b.min.y as u32;
        let width = rgba.width();
        let buf = rgba.as_mut();
        let alpha = (conf.background_opacity * 255.0) as u32;
        let inv_alpha = 255 - alpha;

        for y in min_y..=max_y {
            let row_offset = (y * width * 4) as usize;
            for x in min_x..=max_x {
                if (x == max_x || x == min_x) && (y == max_y || y == min_y) {
                    continue;
                }
                let idx = row_offset + (x * 4) as usize;
                buf[idx] = ((buf[idx] as u32 * inv_alpha) / 255) as u8;
                buf[idx + 1] = ((buf[idx + 1] as u32 * inv_alpha) / 255) as u8;
                buf[idx + 2] = ((buf[idx + 2] as u32 * inv_alpha) / 255) as u8;
            }
        }
    }

    // label
    for glyph in outline_glyphs {
        let bounds = glyph.px_bounds();
        glyph.draw(|x, y, c| {
            let px = rgba.get_pixel_mut(x + bounds.min.x as u32, y + bounds.min.y as u32);
            px.blend(&image::Rgba([255, 255, 255, (c * 255.0) as u8]));
        });
    }

    Ok(rgba.into())
}

/// Draw a label directly into a region of an existing RGB grid. This avoids cloning
/// each capture tile only to overlay its timestamp before copying it into the grid.
pub fn draw_rgb_region(
    image: &mut image::RgbImage,
    origin_x: u32,
    origin_y: u32,
    region_width: u32,
    region_height: u32,
    label: &str,
    conf: &Config,
) -> anyhow::Result<()> {
    if label.is_empty() {
        return Ok(());
    }

    let region_width_f = region_width as f32;
    let region_height_f = region_height as f32;
    let min_dim = region_width_f.min(region_height_f);
    let font = &*FONT;
    let scale = PxScale::from(min_dim * conf.scale_percent);
    let margin = min_dim * conf.margin_percent;
    let pad = min_dim * conf.padding_percent;
    let layout = glyph_brush_layout::Layout::default_single_line()
        .v_align(VerticalAlign::Bottom)
        .h_align(HorizontalAlign::Right);
    let geometry = SectionGeometry {
        screen_position: (region_width_f - margin * 2.0, region_height_f - margin),
        bounds: (region_width_f, region_height_f),
    };
    let glyphs = layout.calculate_glyphs(
        &[&font],
        &geometry,
        &[SectionText {
            text: label,
            scale,
            ..<_>::default()
        }],
    );
    let outline_glyphs: Vec<_> = glyphs
        .into_iter()
        .filter_map(|glyph| font.outline_glyph(glyph.glyph))
        .collect();

    if let Some(bounds) = outline_bounds(&layout, &geometry, &outline_glyphs, pad) {
        let max_x = (bounds.max.x.ceil() as u32).min(region_width - 1);
        let min_x = bounds.min.x.max(0.0) as u32;
        let max_y = (bounds.max.y.ceil() as u32).min(region_height - 1);
        let min_y = bounds.min.y.max(0.0) as u32;
        let alpha = (conf.background_opacity * 255.0) as u32;
        let inv_alpha = 255 - alpha;
        for y in min_y..=max_y {
            for x in min_x..=max_x {
                if (x == max_x || x == min_x) && (y == max_y || y == min_y) {
                    continue;
                }
                let pixel = image.get_pixel_mut(origin_x + x, origin_y + y);
                pixel.0[0] = ((pixel.0[0] as u32 * inv_alpha) / 255) as u8;
                pixel.0[1] = ((pixel.0[1] as u32 * inv_alpha) / 255) as u8;
                pixel.0[2] = ((pixel.0[2] as u32 * inv_alpha) / 255) as u8;
            }
        }
    }

    for glyph in outline_glyphs {
        let bounds = glyph.px_bounds();
        glyph.draw(|x, y, coverage| {
            let pixel = image.get_pixel_mut(
                origin_x + x + bounds.min.x.max(0.0) as u32,
                origin_y + y + bounds.min.y.max(0.0) as u32,
            );
            let alpha = (coverage * 255.0) as u32;
            for channel in &mut pixel.0 {
                *channel = ((*channel as u32 * (255 - alpha) + 255 * alpha) / 255) as u8;
            }
        });
    }
    Ok(())
}

fn outline_bounds(
    layout: &glyph_brush_layout::Layout<glyph_brush_layout::BuiltInLineBreaker>,
    geometry: &SectionGeometry,
    glyphs: &[glyph_brush_layout::ab_glyph::OutlinedGlyph],
    pad: f32,
) -> Option<Rect> {
    glyphs
        .iter()
        .map(|glyph| glyph.px_bounds())
        .fold(None, |bounds: Option<Rect>, next| {
            bounds
                .map(|bounds| Rect {
                    min: point(bounds.min.x.min(next.min.x), bounds.min.y.min(next.min.y)),
                    max: point(bounds.max.x.max(next.max.x), bounds.max.y.max(next.max.y)),
                })
                .or(Some(next))
        })
        .map(|mut bounds| {
            let Rect { min, max } = layout.bounds_rect(geometry);
            bounds.min.x = bounds.min.x.max(min.x) - pad;
            bounds.min.y = bounds.min.y.max(min.y) - pad;
            bounds.max.x = bounds.max.x.min(max.x) + pad;
            bounds.max.y = bounds.max.y.min(max.y) + pad;
            bounds
        })
}

pub fn seconds_text(seconds: u32) -> String {
    let hours = seconds / 3600;
    let mins = (seconds / 60) % 60;
    let secs = seconds % 60;
    match (hours, mins, secs) {
        (0, m, s) => format!("{m:02}:{s:02}"),
        (h, m, s) => format!("{h}:{m:02}:{s:02}"),
    }
}
