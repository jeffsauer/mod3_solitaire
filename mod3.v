module main

import gg
import rand
import time
import sokol.audio
import v.embed_file

// Default card dimensions (500x726)
const default_card_width = 500
const default_card_height = 726

// Scale down factor for rendering so 500x726 fits comfortably on screen
const render_scale = 0.16

const card_width = int(default_card_width * render_scale)
const card_height = int(default_card_height * render_scale)
const card_margin = 25
const start_x = 40
const start_y = 100
const cols = 8

// Calculate window size to closely fit the playing area
const default_width = (cols * card_width) + ((cols - 1) * card_margin) + (start_x * 2) +
	card_width + 40
const default_height = (4 * (card_height + card_margin + 35)) + start_y + 60

// Cascading offsets when cards stack in a pile slot
const stack_offset_x = 0
const stack_offset_y = 14

enum Suit {
	hearts
	diamonds
	clubs
	spades
}

// Context holder to track PCM data stream and concurrent sound voices
struct WavPlayer {
mut:
	samples    []f32
	active_pos []int
}

struct Card {
mut:
	suit Suit
	rank int // 2-10, 11=J, 12=Q, 13=K
}

// Tracks physics state for cards during the victory sequence
struct VictoryCard {
mut:
	card   Card
	x      f32
	y      f32
	vx     f32
	vy     f32
	active bool
}

// Snapshot for UNDO functionality
struct UndoState {
	deck       []Card
	grid       [][]Card
	move_count int
	is_won     bool
	message    string
}

// Animation data structure for card movement
struct Animation {
	card       Card
	start_x    f32
	start_y    f32
	end_x      f32
	end_y      f32
	start_time i64
	duration   f32 // in milliseconds
	target_r   int
	target_c   int
mut:
	sound_played bool
}

struct App {
mut:
	ctx        &gg.Context = unsafe { nil }
	deck       []Card
	grid       [][]Card
	undo_stack []UndoState
	animations []Animation
	move_count int
	is_won     bool
	selected_r int    = -1
	selected_c int    = -1
	message    string = 'Click a card to select, then click a target slot. Double-click to auto-play!'
	is_muted   bool
	card_flip  ?&WavPlayer

	victory_cards []VictoryCard

	// Double-click tracking state
	last_click_time i64
	last_click_r    int = -1
	last_click_c    int = -1

	card_atlas gg.Image
}

fn main() {
	// Embed the card atlas image binary directly into the compiled executable
	embedded_atlas := $embed_file('PNG-cards-1.3/card_atlas.png')

	// Embed the card flip sound binary directly into the compiled executable
	embedded_card_flip_sound := $embed_file('sounds/card_flip.wav')

	mut app := &App{}

	app.ctx = gg.new_context(
		bg_color:     gg.rgb(34, 112, 62)
		width:        default_width
		height:       default_height
		window_title: 'Mod3 Solitaire'
		init_fn:      fn [embedded_atlas, embedded_card_flip_sound] (mut app App) {
			// Initialize card images directly from embedded binary data
			app.card_atlas = use_card_atlas(mut app.ctx, embedded_atlas)

			// Initialize card flip sound directly from embedded binary data
			if player := use_card_flip_sound(embedded_card_flip_sound) {
				app.card_flip = player

				// Setup audio stream once globally during startup
				audio.setup(
					sample_rate:        44100
					num_channels:       2
					stream_userdata_cb: audio_stream_callback
					user_data:          voidptr(player)
				)
			}

			app.new_game()
		}
		frame_fn:     frame
		click_fn:     on_click
		user_data:    app
	)

	app.ctx.run()
}

// use_card_atlas creates a gg.Image directly from an embedded file buffer
fn use_card_atlas(mut ctx gg.Context, embedded_file embed_file.EmbedFileData) gg.Image {
	bytes := embedded_file.to_bytes()
	return ctx.create_image_from_byte_array(bytes, gg.ImageConfig{}) or {
		panic('Failed to load card atlas texture from embedded file: ${err}')
	}
}

fn use_card_flip_sound(embedded_file embed_file.EmbedFileData) ?&WavPlayer {
	bytes := embedded_file.to_bytes()

	// Extract the raw PCM frames bypassing the 44-byte RIFF header
	data_offset := 44
	if bytes.len <= data_offset {
		return none
	}

	raw_data := bytes[data_offset..]

	// Normalize 16-bit integer bytes into 32-bit floats (-1.0 to 1.0)
	mut float_samples := []f32{cap: raw_data.len / 2}
	for i := 0; i < raw_data.len; i += 2 {
		if i + 1 >= raw_data.len {
			break
		}
		raw_val := u16(raw_data[i]) | (u16(raw_data[i + 1]) << 8)
		val := i16(raw_val)
		float_samples << f32(val) / 32768.0
	}

	// Allocate memory on heap so background streaming thread can access safely
	mut player := &WavPlayer{
		samples:    float_samples
		active_pos: []int{}
	}

	return player
}

fn (mut app App) new_game() {
	app.deck.clear()
	app.undo_stack.clear()
	app.animations.clear()
	app.victory_cards.clear()
	app.move_count = 0
	app.is_won = false
	app.selected_r = -1
	app.selected_c = -1
	app.message = 'New Game started. Build sequences in rows 1-3!'

	app.grid = [][]Card{cap: 32}
	for _ in 0 .. 32 {
		app.grid << []Card{}
	}

	suits := [Suit.hearts, Suit.diamonds, Suit.clubs, Suit.spades]
	for _ in 0 .. 2 {
		for s in suits {
			for r in 2 .. 14 {
				app.deck << Card{
					suit: s
					rank: r
				}
			}
		}
	}
	rand.shuffle(mut app.deck) or {}

	mut temp_deck := app.deck.clone()
	app.deck.clear()

	mut delay_offset := f32(0.0)
	for i in 0 .. 32 {
		if temp_deck.len > 0 {
			card := temp_deck.pop()
			app.grid[i] << card

			r := i / cols
			c := i % cols

			app.animate_deal_from_talon(card, r, c, delay_offset)
			delay_offset += 45.0
		}
	}

	app.deck = temp_deck
}

fn get_scale(ctx &gg.Context) f32 {
	scale_w := f32(ctx.width) / f32(default_width)
	scale_h := f32(ctx.height) / f32(default_height)
	if scale_w < scale_h {
		return scale_w
	}
	return scale_h
}

fn (mut app App) animate_card_move(card Card, start_px f32, start_py f32, target_r int, target_c int, delay_ms f32) {
	scale := get_scale(app.ctx)
	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	row_y := start_y_f + f32(target_r) * (card_h + card_m + 35.0 * scale)
	base_x := start_x_f + f32(target_c) * (card_w + card_m)

	slot_idx := target_r * cols + target_c
	pile_len := app.grid[slot_idx].len - 1

	target_x := base_x + f32(pile_len) * (f32(stack_offset_x) * scale)
	target_y := row_y + f32(pile_len) * (f32(stack_offset_y) * scale)

	now := time.ticks()
	app.animations << Animation{
		card:         card
		start_x:      start_px
		start_y:      start_py
		end_x:        target_x
		end_y:        target_y
		start_time:   now + i64(delay_ms)
		duration:     400.0
		target_r:     target_r
		target_c:     target_c
		sound_played: false
	}
}

fn (mut app App) animate_deal_from_talon(card Card, target_r int, target_c int, delay_ms f32) {
	scale := get_scale(app.ctx)
	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	side_x := start_x_f + f32(cols) * (card_w + card_m) + 20.0 * scale
	talon_y := start_y_f + 3.0 * (card_h + card_m + 35.0 * scale)
	app.animate_card_move(card, side_x, talon_y, target_r, target_c, delay_ms)
}

fn (mut app App) save_undo_state() {
	mut grid_copy := [][]Card{cap: app.grid.len}
	for pile in app.grid {
		grid_copy << pile.clone()
	}

	app.undo_stack << UndoState{
		deck:       app.deck.clone()
		grid:       grid_copy
		move_count: app.move_count
		is_won:     app.is_won
		message:    app.message
	}
}

fn (mut app App) undo_last_move() {
	if app.undo_stack.len == 0 {
		app.message = 'Nothing to undo!'
		return
	}

	state := app.undo_stack.pop()
	app.animations.clear()
	app.deck = state.deck.clone()
	app.grid = state.grid.clone()
	app.move_count = state.move_count
	app.is_won = state.is_won
	app.message = 'Undo successful.'
	app.selected_r = -1
	app.selected_c = -1

	app.play_flip_sound()
}

fn frame(mut app App) {
	app.ctx.begin()

	win_w := app.ctx.width
	win_h := app.ctx.height
	scale := get_scale(app.ctx)

	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	now := time.ticks()

	// Header Area
	app.ctx.draw_text(int(start_x_f), int(14.0 * scale), 'MOD3 SOLITAIRE', gg.TextCfg{
		color: gg.white
		size:  int(22.0 * scale)
		bold:  true
	})

	msg_color := if app.is_won { gg.rgb(100, 255, 100) } else { gg.yellow }
	app.ctx.draw_text(int(start_x_f), int(42.0 * scale), app.message, gg.TextCfg{
		color: msg_color
		size:  int(13.0 * scale)
		bold:  app.is_won
	})

	labels := [
		'Row 1 Target: 2 - 5 - 8 - J',
		'Row 2 Target: 3 - 6 - 9 - Q',
		'Row 3 Target: 4 - 7 - 10 - K',
	]

	// Render Grid (4 Rows x 8 Columns)
	for r in 0 .. 4 {
		row_y := start_y_f + f32(r) * (card_h + card_m + 35.0 * scale)

		if r < 3 {
			app.ctx.draw_text(int(start_x_f), int(row_y - 15.0 * scale), labels[r], gg.TextCfg{
				color: gg.rgb(210, 240, 210)
				size:  int(11.0 * scale)
				bold:  true
			})
		}

		for c in 0 .. cols {
			base_x := start_x_f + f32(c) * (card_w + card_m)
			slot_idx := r * cols + c

			// Base Slot Outline
			app.ctx.draw_rect_empty(base_x, row_y, card_w, card_h, gg.rgba(255, 255, 255, 70))

			pile := app.grid[slot_idx]
			for i in 0 .. pile.len {
				is_top := (i == pile.len - 1)
				mut is_animating := false
				if is_top {
					for anim in app.animations {
						if anim.target_r == r && anim.target_c == c
							&& now < anim.start_time + i64(anim.duration) {
							is_animating = true
							break
						}
					}
				}

				if !is_animating {
					card := pile[i]
					is_selected := is_top && (r == app.selected_r && c == app.selected_c)

					cx := base_x + f32(i) * (f32(stack_offset_x) * scale)
					cy := row_y + f32(i) * (f32(stack_offset_y) * scale)

					draw_card(mut app, int(cx), int(cy), card_w, card_h, card, is_selected)
				}
			}
		}
	}

	side_x := start_x_f + f32(cols) * (card_w + card_m) + 20.0 * scale

	// Restart Button
	restart_y := start_y_f
	btn_h := 35.0 * scale
	app.ctx.draw_rect_filled(side_x, restart_y, card_w, btn_h, gg.rgb(190, 50, 50))
	app.ctx.draw_rect_empty(side_x, restart_y, card_w, btn_h, gg.white)
	app.ctx.draw_text(int(side_x + 6.0 * scale), int(restart_y + 10.0 * scale), 'NEW GAME',
		gg.TextCfg{
		color: gg.white
		size:  int(10.0 * scale)
		bold:  true
	})

	// Undo Button
	undo_y := restart_y + 45.0 * scale
	undo_btn_color := if app.undo_stack.len > 0 { gg.rgb(60, 140, 200) } else { gg.rgb(70, 70, 70) }
	app.ctx.draw_rect_filled(side_x, undo_y, card_w, btn_h, undo_btn_color)
	app.ctx.draw_rect_empty(side_x, undo_y, card_w, btn_h, gg.white)
	app.ctx.draw_text(int(side_x + 14.0 * scale), int(undo_y + 10.0 * scale), 'UNDO', gg.TextCfg{
		color: gg.white
		size:  int(10.0 * scale)
		bold:  true
	})

	// Mute Button
	mute_y := undo_y + 45.0 * scale
	mute_btn_color := if app.is_muted { gg.rgb(150, 60, 60) } else { gg.rgb(60, 120, 90) }
	mute_label := if app.is_muted { 'UNMUTE' } else { 'MUTE' }
	app.ctx.draw_rect_filled(side_x, mute_y, card_w, btn_h, mute_btn_color)
	app.ctx.draw_rect_empty(side_x, mute_y, card_w, btn_h, gg.white)
	app.ctx.draw_text(int(side_x + 10.0 * scale), int(mute_y + 10.0 * scale), mute_label,
		gg.TextCfg{
		color: gg.white
		size:  int(10.0 * scale)
		bold:  true
	})

	// Talon Deck
	talon_y := start_y_f + 3.0 * (card_h + card_m + 35.0 * scale)
	if app.deck.len > 0 {
		app.ctx.draw_image_with_config(gg.DrawImageConfig{
			img:       &app.card_atlas
			img_rect:  gg.Rect{
				x:      side_x
				y:      talon_y
				width:  card_w
				height: card_h
			}
			part_rect: gg.Rect{
				x:      0
				y:      f32(4 * default_card_height) // Row 4 holds the Card Back
				width:  f32(default_card_width)
				height: f32(default_card_height)
			}
		})
		app.ctx.draw_rect_empty(side_x, talon_y, card_w, card_h, gg.black)
	} else {
		app.ctx.draw_rect_empty(side_x, talon_y, card_w, card_h, gg.rgba(255, 255, 255, 70))
	}

	// Render Active Animations and Sync Card Flip Audio Onset
	mut active_anims := []Animation{}
	for mut anim in app.animations {
		if now < anim.start_time {
			active_anims << anim
			continue
		}

		// Trigger card flip sound exact frame animation starts moving on screen
		if !anim.sound_played {
			app.play_flip_sound()
			anim.sound_played = true
		}

		elapsed := f32(now - anim.start_time)
		progress := elapsed / anim.duration

		if progress < 1.0 {
			cur_x := anim.start_x + (anim.end_x - anim.start_x) * progress
			cur_y := anim.start_y + (anim.end_y - anim.start_y) * progress

			draw_card(mut app, int(cur_x), int(cur_y), card_w, card_h, anim.card, false)
			active_anims << anim
		}
	}
	app.animations = active_anims.clone()

	// --- Victory Animation processing ---
	if app.is_won {
		gravity := f32(0.6) * scale
		dampening := f32(0.85)
		for mut vc in app.victory_cards {
			if !vc.active {
				// Keep drawing cards that have settled
				draw_card(mut app, int(vc.x), int(vc.y), card_w, card_h, vc.card, false)
				continue
			}

			// Apply gravity and velocity
			vc.vy += gravity
			vc.x += vc.vx
			vc.y += vc.vy

			// Floor bounce
			if vc.y + card_h > f32(win_h) {
				vc.y = f32(win_h) - card_h
				vc.vy = -vc.vy * dampening
				// Deactivate card to save cycles if energy is very low
				if vc.vy > -1.0 * scale {
					vc.vy = 0
					vc.vx = 0
					vc.active = false
				}
			}
			
			// Wall bounce (left/right)
			if vc.x < 0 {
				vc.x = 0
				vc.vx = -vc.vx * dampening
			} else if vc.x + card_w > f32(win_w) {
				vc.x = f32(win_w) - card_w
				vc.vx = -vc.vx * dampening
			}

			draw_card(mut app, int(vc.x), int(vc.y), card_w, card_h, vc.card, false)
		}
	}
	// --- End of Victory Animation processing ---

	// Victory Banner
	if app.is_won {
		banner_w := 400.0 * scale
		banner_h := 100.0 * scale
		bx := f32(win_w / 2) - (banner_w / 2)
		by := f32(win_h / 2) - (banner_h / 2)

		app.ctx.draw_rect_filled(bx, by, banner_w, banner_h, gg.rgba(0, 0, 0, 210))
		app.ctx.draw_rect_empty(bx, by, banner_w, banner_h, gg.rgb(255, 215, 0))

		app.ctx.draw_text(int(bx + 40.0 * scale), int(by + 20.0 * scale), 'CONGRATULATIONS! YOU WON!',
			gg.TextCfg{
			color: gg.yellow
			size:  int(18.0 * scale)
			bold:  true
		})
		app.ctx.draw_text(int(bx + 90.0 * scale), int(by + 55.0 * scale), 'Completed in ${app.move_count} moves.',
			gg.TextCfg{
			color: gg.white
			size:  int(13.0 * scale)
		})
	}

	// Bottom Bar
	bar_h := 30.0 * scale
	bar_y := f32(win_h) - bar_h
	app.ctx.draw_rect_filled(0, bar_y, f32(win_w), bar_h, gg.rgb(20, 70, 38))
	app.ctx.draw_rect_empty(0, bar_y, f32(win_w), bar_h, gg.rgba(255, 255, 255, 50))

	moves_right_x := f32(win_w) - 120.0 * scale
	app.ctx.draw_text(int(moves_right_x), int(bar_y + 7.0 * scale), 'MOVES: ${app.move_count}',
		gg.TextCfg{
		color: gg.white
		size:  int(12.0 * scale)
		bold:  true
	})

	app.ctx.end()
}

fn draw_card(mut app App, x int, y int, w f32, h f32, card Card, selected bool) {
	// Base sub-image size within atlas
	src_w := f32(default_card_width)
	src_h := f32(default_card_height)

	// Determine atlas row according to atlas layout:
	// 0: Hearts, 1: Diamonds, 2: Spades, 3: Clubs
	row_idx := match card.suit {
		.hearts { 0 }
		.diamonds { 1 }
		.spades { 2 }
		.clubs { 3 }
	}

	// Determine atlas column (2..13 -> col 0..11, Ace/14 -> col 12)
	col_idx := if card.rank == 14 { 12 } else { card.rank - 2 }

	// Calculate pixel offsets within the atlas
	src_x := f32(col_idx) * src_w
	src_y := f32(row_idx) * src_h

	// Render the card using sub-rectangle parameters
	app.ctx.draw_image_with_config(gg.DrawImageConfig{
		img:       &app.card_atlas
		img_rect:  gg.Rect{
			x:      f32(x)
			y:      f32(y)
			width:  w
			height: h
		}
		part_rect: gg.Rect{
			x:      src_x
			y:      src_y
			width:  src_w
			height: src_h
		}
	})

	// Render selection or standard outline border
	if selected {
		app.ctx.draw_rect_empty(f32(x), f32(y), w, h, gg.rgb(255, 140, 0))
		app.ctx.draw_rect_empty(f32(x + 1), f32(y + 1), w - 2.0, h - 2.0, gg.rgb(255, 200, 0))
	} else {
		app.ctx.draw_rect_empty(f32(x), f32(y), w, h, gg.black)
	}
}

fn on_click(x f32, y f32, button gg.MouseButton, mut app App) {
	if button != .left {
		return
	}

	scale := get_scale(app.ctx)
	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	side_x := start_x_f + f32(cols) * (card_w + card_m) + 20.0 * scale

	// 1. Click New Game Button
	restart_y := start_y_f
	btn_h := 35.0 * scale
	if x >= side_x && x <= side_x + card_w && y >= restart_y && y <= restart_y + btn_h {
		app.new_game()
		return
	}

	// 2. Click Undo Button
	undo_y := restart_y + 45.0 * scale
	if x >= side_x && x <= side_x + card_w && y >= undo_y && y <= undo_y + btn_h {
		app.undo_last_move()
		return
	}

	// 3. Click Mute Button
	mute_y := undo_y + 45.0 * scale
	if x >= side_x && x <= side_x + card_w && y >= mute_y && y <= mute_y + btn_h {
		app.is_muted = !app.is_muted
		app.message = if app.is_muted { 'Audio muted.' } else { 'Audio unmuted.' }
		return
	}

	// 4. Click Talon
	talon_y := start_y_f + 3.0 * (card_h + card_m + 35.0 * scale)
	if x >= side_x && x <= side_x + card_w && y >= talon_y && y <= talon_y + card_h {
		app.deal_from_talon()
		return
	}

	// 5. Click Grid Cards
	for r in 0 .. 4 {
		row_y := start_y_f + f32(r) * (card_h + card_m + 35.0 * scale)

		for c in 0 .. cols {
			gx_pos := start_x_f + f32(c) * (card_w + card_m)
			slot_idx := r * cols + c
			pile_len := app.grid[slot_idx].len

			stack_w := card_w
			stack_h := card_h + if pile_len > 1 {
				f32(pile_len - 1) * (f32(stack_offset_y) * scale)
			} else {
				0.0
			}

			if x >= gx_pos && x <= gx_pos + stack_w && y >= row_y && y <= row_y + stack_h {
				app.handle_grid_click(r, c)
				return
			}
		}
	}
}

// Strictly evaluate Mod3 move rules ensuring correct base cards and prior sequence steps
fn (app App) is_valid_move(card Card, to_r int, to_c int) bool {
	dest_idx := to_r * cols + to_c
	dest_pile := app.grid[dest_idx]

	// Row 4 (index 3) is Waste / Free slots: accepts ANY single card into an empty slot
	if to_r == 3 {
		return dest_pile.len == 0
	}

	// Rows 1-3 (indices 0-2) strictly hold sequences of length 4 max
	if dest_pile.len >= 4 {
		return false
	}

	// If the slot is empty, it can only accept the base card for this row:
	// Row 1 (to_r = 0) -> 2
	// Row 2 (to_r = 1) -> 3
	// Row 3 (to_r = 2) -> 4
	if dest_pile.len == 0 {
		return card.rank == (2 + to_r)
	}

	// Calculate expected rank for current depth in sequence
	expected_rank := 2 + to_r + (dest_pile.len * 3)
	if card.rank != expected_rank {
		return false
	}

	// The existing pile must have the correct previous card rank in the sequence and matching suit
	expected_prev_rank := 2 + to_r + ((dest_pile.len - 1) * 3)
	top_card := dest_pile.last()

	if top_card.rank != expected_prev_rank || top_card.suit != card.suit {
		return false
	}

	return true
}

// Auto-target finding logic strictly matching Mod3 sequence rules
fn (app App) find_auto_target(card Card, src_r int, src_c int) (int, int) {
	// First check target sequence building rows (Rows 0, 1, and 2)
	for tr in 0 .. 3 {
		for tc in 0 .. cols {
			if tr == src_r && tc == src_c {
				continue
			}
			if app.is_valid_move(card, tr, tc) {
				return tr, tc
			}
		}
	}

	// If the card is in a target row but blocked, allow auto-moving to Row 4 empty slot
	if src_r < 3 {
		for tc in 0 .. cols {
			if app.is_valid_move(card, 3, tc) {
				return 3, tc
			}
		}
	}

	return -1, -1
}

fn (mut app App) handle_grid_click(r int, c int) {
	slot_idx := r * cols + c

	now := time.ticks()
	is_double_click := (app.last_click_r == r && app.last_click_c == c
		&& (now - app.last_click_time) < 350)

	app.last_click_time = now
	app.last_click_r = r
	app.last_click_c = c

	// Handle Double-Click Auto Play
	if is_double_click && app.grid[slot_idx].len > 0 {
		card := app.grid[slot_idx].last()
		target_r, target_c := app.find_auto_target(card, r, c)

		if target_r != -1 && target_c != -1 {
			app.execute_move(r, c, target_r, target_c)
			app.selected_r = -1
			app.selected_c = -1
			return
		} else {
			app.message = 'No valid Mod3 sequence target available for this card.'
		}
	}

	// Standard Selection & Movement Rules
	if app.selected_r == -1 {
		if app.grid[slot_idx].len > 0 {
			app.selected_r = r
			app.selected_c = c
			card := app.grid[slot_idx].last()
			app.message = 'Selected: ${card.rank} of ${card.suit}'
		}
		return
	}

	if app.selected_r == r && app.selected_c == c {
		app.selected_r = -1
		app.selected_c = -1
		app.message = 'Selection cleared.'
		return
	}

	from_r := app.selected_r
	from_c := app.selected_c
	from_idx := from_r * cols + from_c

	if app.grid[from_idx].len > 0 {
		card := app.grid[from_idx].last()
		if app.is_valid_move(card, r, c) {
			app.execute_move(from_r, from_c, r, c)
		} else {
			app.message = 'Invalid move according to Mod3-style sequence rules!'
		}
	}

	app.selected_r = -1
	app.selected_c = -1
}

fn (mut app App) execute_move(from_r int, from_c int, to_r int, to_c int) {
	from_idx := from_r * cols + from_c
	to_idx := to_r * cols + to_c

	app.save_undo_state()

	scale := get_scale(app.ctx)
	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	start_px := start_x_f + f32(from_c) * (card_w + card_m)
	from_pile_len := app.grid[from_idx].len - 1
	start_py := start_y_f + f32(from_r) * (card_h + card_m + 35.0 * scale) +
		(f32(from_pile_len) * (f32(stack_offset_y) * scale))

	moved_card := app.grid[from_idx].pop()
	app.grid[to_idx] << moved_card
	app.move_count++
	app.message = 'Moved card successfully.'

	app.animate_card_move(moved_card, start_px, start_py, to_r, to_c, 0)
	app.fill_empty_row4_slots()
	app.check_win_condition()
}

fn (mut app App) fill_empty_row4_slots() {
	mut delay_offset := f32(0.0)
	for c in 0 .. cols {
		slot_idx := 3 * cols + c
		if app.grid[slot_idx].len == 0 && app.deck.len > 0 {
			card := app.deck.pop()
			app.grid[slot_idx] << card

			app.animate_deal_from_talon(card, 3, c, delay_offset)
			delay_offset += 75.0

			app.message += ' Auto-filled Row 4 slot from Talon.'
		}
	}
}

fn (mut app App) check_win_condition() {
	if app.deck.len > 0 {
		return
	}

	for c in 0 .. cols {
		slot_idx := 3 * cols + c
		if app.grid[slot_idx].len > 0 {
			return
		}
	}

	for r in 0 .. 3 {
		for c in 0 .. cols {
			slot_idx := r * cols + c
			if app.grid[slot_idx].len != 4 {
				return
			}
		}
	}

	app.is_won = true
	app.message = 'YOU WIN! All target sequences are complete!'
	app.trigger_victory_animation()
}

// New function to initialize the physics for all cards
fn (mut app App) trigger_victory_animation() {
	scale := get_scale(app.ctx)
	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	app.victory_cards.clear()

	for r in 0 .. 4 {
		for c in 0 .. cols {
			slot_idx := r * cols + c
			for i, card in app.grid[slot_idx] {
				base_x := start_x_f + f32(c) * (card_w + card_m)
				row_y := start_y_f + f32(r) * (card_h + card_m + 35.0 * scale)
				cx := base_x + f32(i) * (f32(stack_offset_x) * scale)
				cy := row_y + f32(i) * (f32(stack_offset_y) * scale)

				// Assign random velocities for an explosion effect
				vx := (rand.f32() * 16.0 - 8.0) * scale
				vy := (rand.f32() * -15.0 - 5.0) * scale

				app.victory_cards << VictoryCard{
					card: card
					x: cx
					y: cy
					vx: vx
					vy: vy
					active: true
				}
			}
			// Clear the grid pile so static cards aren't drawn anymore
			app.grid[slot_idx].clear()
		}
	}
}


fn (mut app App) deal_from_talon() {
	if app.deck.len == 0 {
		app.message = 'Talon is empty!'
		return
	}

	app.save_undo_state()

	mut dealt := 0
	mut delay_offset := f32(0.0)

	for c in 0 .. cols {
		if app.deck.len > 0 {
			slot_idx := 3 * cols + c
			card := app.deck.pop()
			app.grid[slot_idx] << card

			app.animate_deal_from_talon(card, 3, c, delay_offset)
			delay_offset += 75.0

			dealt++
		}
	}

	app.message = 'Dealt ${dealt} card(s) across Row 4 slots.'
	app.check_win_condition()
}

// Background thread callback mixing active PCM sound stream instances
fn audio_stream_callback(buffer &f32, num_frames int, num_channels int, user_data voidptr) {
	mut player := unsafe { &WavPlayer(user_data) }
	num_samples := num_frames * num_channels

	unsafe {
		mut buf := buffer
		// Clear audio buffer
		for i in 0 .. num_samples {
			buf[i] = 0.0
		}

		// Mix samples for all active voices
		mut remaining_positions := []int{}
		for pos in player.active_pos {
			mut cur_pos := pos
			for i in 0 .. num_samples {
				if cur_pos < player.samples.len {
					buf[i] += player.samples[cur_pos]
					cur_pos++
				} else {
					break
				}
			}

			// Keep voice in active list if sound isn't complete yet
			if cur_pos < player.samples.len {
				remaining_positions << cur_pos
			}
		}
		player.active_pos = remaining_positions
	}
}

// Queues a new card flip sound instance into the active audio stream
fn (mut app App) play_flip_sound() {
	if app.is_muted {
		return
	}
	if mut player := app.card_flip {
		player.active_pos << 0
	}
}

