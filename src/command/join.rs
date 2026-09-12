pub mod label;

use anyhow::{anyhow, ensure};
use image::GenericImage;
use rayon::prelude::*;
use std::path::{Path, PathBuf};

/// Join same-sized capture images into a single grid image.
#[derive(clap::Parser, Debug, Clone)]
#[group(skip)]
pub struct Join {
    /// Number of capture columns in output.
    #[arg(long, short)]
    pub columns: u32,

    /// Pixel width of each capture inside the grid. Will be scaled preserving aspect.
    #[arg(long, short = 'W')]
    pub capture_width: Option<u32>,

    /// Pixel height of each capture inside the grid. Will be scaled preserving aspect.
    #[arg(long, short = 'H')]
    pub capture_height: Option<u32>,

    /// Output file name.
    #[arg(long, short)]
    pub output: PathBuf,

    #[arg(long)]
    pub label: Vec<String>,

    /// Images to join.
    #[arg(required = true)]
    pub capture_images: Vec<PathBuf>,
}

impl Join {
    pub fn run(&self) -> anyhow::Result<()> {
        let Self {
            columns,
            output,
            capture_images,
            ..
        } = self;

        let n_captures = capture_images.len() as u32;

        // load images concurrently
        let images: Vec<_> = capture_images
            .par_iter()
            .map(|i| self.load_image(i).map_err(|e| anyhow!("{i:?}: {e}")))
            .collect::<Result<Vec<_>, _>>()?;

        let (cap_w, cap_h) = (images[0].width(), images[0].height());
        let (rows, cols) = if *columns == 0 || n_captures <= *columns {
            (1, n_captures)
        } else {
            let images = n_captures;
            let mut rows = images / columns;
            if !images.is_multiple_of(*columns) {
                rows += 1;
            }
            (rows, *columns)
        };

        let mut labels = self.label.clone();
        labels.resize_with(images.len(), String::new);

        let mut all = image::RgbaImage::new(cap_w * cols, cap_h * rows);
        for (idx, (img, label)) in images.into_iter().zip(labels).enumerate() {
            let idx = idx as u32;
            let x = (idx % cols) * cap_w;
            let y = (idx / cols) * cap_h;
            let img = label::draw(img, &label, &label::Config::default())?;
            all.copy_from(&img, x as _, y as _)?;
        }

        image::DynamicImage::from(all).into_rgb8().save(output)?;

        Ok(())
    }

    fn load_image(&self, path: impl AsRef<Path>) -> anyhow::Result<image::DynamicImage> {
        let path = path.as_ref();
        let mut img = image::ImageReader::open(path)?.decode()?;

        if self.capture_width.is_some() || self.capture_height.is_some() {
            img = img.resize(
                self.capture_width.unwrap_or(u32::MAX),
                self.capture_height.unwrap_or(u32::MAX),
                image::imageops::FilterType::CatmullRom,
            );
        }

        Ok(img)
    }
}

/// One capture attempt's grid layout and timestamp coverage. No frame pixels
/// are cached, so each animation frame blends against its own video content.
pub(crate) struct MemoryJoiner {
    capture_dimensions: (u32, u32),
    grid_dimensions: (u32, u32),
    columns: u32,
    labels: Vec<label::RgbLabel>,
}

impl MemoryJoiner {
    pub(crate) fn new(
        capture_dimensions: (u32, u32),
        capture_count: usize,
        columns: u32,
        labels: &[String],
    ) -> anyhow::Result<Self> {
        let count = u32::try_from(capture_count)?;
        let (width, height) = capture_dimensions;
        ensure!(count > 0 && width > 0 && height > 0, "empty capture grid");
        let columns = if columns == 0 {
            count
        } else {
            columns.min(count)
        };
        let rows = count.div_ceil(columns);
        let grid_dimensions = (
            width
                .checked_mul(columns)
                .ok_or_else(|| anyhow!("grid width overflow"))?,
            height
                .checked_mul(rows)
                .ok_or_else(|| anyhow!("grid height overflow"))?,
        );
        let config = label::Config::default();
        let labels = (0..capture_count)
            .map(|index| {
                label::RgbLabel::new(
                    width,
                    height,
                    labels.get(index).map_or("", String::as_str),
                    &config,
                )
            })
            .collect();
        Ok(Self {
            capture_dimensions,
            grid_dimensions,
            columns,
            labels,
        })
    }

    pub(crate) fn join(&self, images: &[&image::RgbImage]) -> anyhow::Result<image::RgbImage> {
        ensure!(
            images.len() == self.labels.len(),
            "capture count changed while joining"
        );
        let (width, height) = self.capture_dimensions;
        let mut all = image::RgbImage::new(self.grid_dimensions.0, self.grid_dimensions.1);
        let grid_stride = all.width() as usize * 3;
        let row_bytes = width as usize * 3;
        for (index, (image, label)) in images.iter().zip(&self.labels).enumerate() {
            ensure!(
                image.dimensions() == self.capture_dimensions,
                "capture dimensions changed while joining"
            );
            let x = (index as u32 % self.columns) * width;
            let y = (index as u32 / self.columns) * height;
            // RgbImage stores packed RGB rows. image 0.25.8's GenericImage
            // copy_from visits every pixel; copy each checked row directly.
            for (row, source) in image.as_raw()[..row_bytes * height as usize]
                .chunks_exact(row_bytes)
                .enumerate()
            {
                let offset = (y as usize + row) * grid_stride + x as usize * 3;
                all.as_mut()[offset..offset + row_bytes].copy_from_slice(source);
            }
            label.draw_into(&mut all, x, y);
        }
        Ok(all)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reused_grid_preserves_tiles_labels_and_empty_cells() {
        let labels = vec!["01:23".to_owned(), "04:56".to_owned()];
        for columns in [0, 1, 2, 3, 7] {
            let joiner = MemoryJoiner::new((80, 64), 3, columns, &labels).unwrap();
            for frame in 0..3 {
                let images: Vec<_> = (0..3)
                    .map(|index| {
                        image::RgbImage::from_fn(80, 64, |x, y| {
                            image::Rgb([(x + frame * 77) as u8, (y + index * 83) as u8, 127])
                        })
                    })
                    .collect();
                let columns = if columns == 0 { 3 } else { columns.min(3) };
                let mut reference =
                    image::RgbImage::new(80 * columns, 64 * 3_u32.div_ceil(columns));
                for (index, image) in images.iter().enumerate() {
                    let x = index as u32 % columns * 80;
                    let y = index as u32 / columns * 64;
                    reference.copy_from(image, x, y).unwrap();
                    label::draw_rgb_region(
                        &mut reference,
                        x,
                        y,
                        80,
                        64,
                        labels.get(index).map_or("", String::as_str),
                        &label::Config::default(),
                    )
                    .unwrap();
                }
                let grid = joiner.join(&images.iter().collect::<Vec<_>>()).unwrap();
                assert_eq!(grid.as_raw(), reference.as_raw());
            }
        }
        let joiner = MemoryJoiner::new((80, 64), 1, 1, &labels).unwrap();
        assert!(joiner.join(&[]).is_err());
        assert!(joiner.join(&[&image::RgbImage::new(81, 64)]).is_err());
    }
}
