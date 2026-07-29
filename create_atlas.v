import stbi

enum Suit {
	hearts
	diamonds
	clubs
	spades
}

// create_card_atlas loads all standard card faces and card back PNGs,
// stitching them into a single composite image atlas and registering it with gg.
//
// Layout:
//   Row 0: Hearts (2 to 10, J, Q, K, A)
//   Row 1: Diamonds (2 to 10, J, Q, K, A)
//   Row 2: Spades (2 to 10, J, Q, K, A)
//   Row 3: Clubs (2 to 10, J, Q, K, A)
//   Row 4: Card Back (at 0,0 of Row 4)

fn main() {
	// Base card dimensions (500x726)
	card_w := 500
	card_h := 726

	// Grid configuration: 13 columns (ranks 2-13/Ace) x 5 rows
	atlas_cols := 13
	atlas_rows := 5
	atlas_w := card_w * atlas_cols
	atlas_h := card_h * atlas_rows
	channels := 4 // RGBA

	// Allocate buffer for the complete atlas canvas initialized to transparent/zero
	mut atlas_data := []u8{len: atlas_w * atlas_h * channels}

	// Define suit rows as requested: 0=Hearts, 1=Diamonds, 2=Spades, 3=Clubs
	row_suits := [Suit.hearts, Suit.diamonds, Suit.spades, Suit.clubs]

	for row_idx, suit in row_suits {
		for rank in 2 .. 15 { // Ranks 2 through 14 (14 = Ace)
			col_idx := rank - 2
			key := card_texture_key(if rank == 14 { 1 } else { rank }, suit)
			file_path := 'PNG-cards-1.3/${key}.png'

			// Load individual card raw RGBA pixel data via stbi
			stbi_img := stbi.load(file_path) or {
				panic('Failed to load card image for atlas: ${file_path}')
			}

			dest_x := col_idx * card_w
			dest_y := row_idx * card_h

			// Clamp image bounds to avoid buffer overflow if image size varies slightly
			copy_w := if stbi_img.width < card_w { stbi_img.width } else { card_w }
			copy_h := if stbi_img.height < card_h { stbi_img.height } else { card_h }
			row_bytes := copy_w * channels

			// Copy pixel rows into atlas buffer using byte pointer offsets
			for y in 0 .. copy_h {
				src_offset := y * stbi_img.width * stbi_img.nr_channels
				dest_offset := ((dest_y + y) * atlas_w + dest_x) * channels

				unsafe {
					dest_ptr := &u8(atlas_data.data) + dest_offset
					src_ptr := &u8(stbi_img.data) + src_offset
					vmemcpy(dest_ptr, src_ptr, row_bytes)
				}
			}

			// Free pixel memory loaded by stbi
			stbi_img.free()
		}
	}

	// Load Card Back into Row 4, Column 0
	back_path := 'PNG-cards-1.3/card_back.png'
	back_img := stbi.load(back_path) or {
		panic('Failed to load card_back.png for atlas: ${back_path}')
	}

	dest_y_back := 4 * card_h
	copy_back_w := if back_img.width < card_w { back_img.width } else { card_w }
	copy_back_h := if back_img.height < card_h { back_img.height } else { card_h }
	row_back_bytes := copy_back_w * channels

	for y in 0 .. copy_back_h {
		src_offset := y * back_img.width * back_img.nr_channels
		dest_offset := ((dest_y_back + y) * atlas_w) * channels

		unsafe {
			dest_ptr := &u8(atlas_data.data) + dest_offset
			src_ptr := &u8(back_img.data) + src_offset
			vmemcpy(dest_ptr, src_ptr, row_back_bytes)
		}
	}
	back_img.free()

	// Encode the stitched RGBA pixel buffer to a PNG atlas image file using stbi
	atlas_path := 'PNG-cards-1.3/card_atlas.png'
	stbi.stbi_write_png(atlas_path, atlas_w, atlas_h, channels, atlas_data.data, atlas_w * channels) or {
		panic('Failed to write card atlas PNG: ${err}')
	}
}

// Convert card rank integer and Suit enum into filename stem
fn card_texture_key(rank int, suit Suit) string {
	suit_str := match suit {
		.hearts { 'hearts' }
		.diamonds { 'diamonds' }
		.clubs { 'clubs' }
		.spades { 'spades' }
	}

	rank_str := match rank {
		11 { 'jack' }
		12 { 'queen' }
		13 { 'king' }
		else { rank.str() }
	}

	return '${rank_str}_of_${suit_str}'
}

