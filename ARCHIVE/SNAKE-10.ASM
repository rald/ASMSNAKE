.8086                ; Enforce strict 16-bit 8086 instructions
.model tiny          ; Tiny model combines code/data into one segment for .COM
.code
org 100h             ; COM files must start at memory offset 100h

; -------------------------------------------------------------------------
; CONSTANTS
; -------------------------------------------------------------------------
VGAMODE13     EQU 0013h
TEXTMODE      EQU 0003h
ESC_KEY       EQU 27
MAX_SNAKE_LEN EQU 150
SEG_SIZE      EQU 5   ; Snake segment and food size in pixels

; BIOS Scan Codes for Arrow Keys
KEY_UP        EQU 48h
KEY_DOWN      EQU 50h
KEY_LEFT      EQU 4Bh
KEY_RIGHT     EQU 4Dh

; -------------------------------------------------------------------------
; ENTRY POINT
; -------------------------------------------------------------------------
start:
    ; 1. Seed the Random Number Generator using BIOS timer ticks
    mov ah, 00h
    int 1ah            ; CX:DX = number of clock ticks since midnight
    push dx            ; Pass low word of timer tick as seed
    call SRand

    ; 2. Initialize Snake Position and Length
    mov word ptr [snake_len], 3
    mov word ptr [snake_x], 160   ; Head X
    mov word ptr [snake_y], 100   ; Head Y
    mov word ptr [snake_x+2], 155 ; Segment 1 X
    mov word ptr [snake_y+2], 100 ; Segment 1 Y
    mov word ptr [snake_x+4], 150 ; Segment 2 X
    mov word ptr [snake_y+4], 100 ; Segment 2 Y

    ; 3. Spawn first food item safely away from the snake
    call spawn_food

    ; 4. Set Mode 13h (320x200, 256 colors)
    mov ax, VGAMODE13
    call SetMode

    ; 5. Load the Sweetie-16 Palette
    call LoadSweetie16

    ; 6. Initial Full Screen Clear (Black background)
    xor ax, ax
    push ax          ; C (Black)
    mov ax, 200
    push ax          ; H
    mov ax, 320
    push ax          ; W
    xor ax, ax       ; Y
    push ax          ; Y
    push ax          ; X
    call FillRect

    ; Draw initial food
    mov ax, 3        ; Color 3 (Orange)
    push ax          
    mov ax, SEG_SIZE
    push ax          ; H
    mov ax, SEG_SIZE
    push ax          ; W
    mov ax, [food_y]
    push ax          ; Y
    mov ax, [food_x]
    push ax          ; X
    call FillRect

    ; Draw initial snake segments
    mov cx, [snake_len]
    xor si, si
init_draw_snake:
    mov ax, 5        ; Color 5 (Light Green)
    push ax          
    mov ax, SEG_SIZE
    push ax          ; H
    mov ax, SEG_SIZE
    push ax          ; W
    mov ax, [snake_y + si]
    push ax          ; Y
    mov ax, [snake_x + si]
    push ax          ; X
    call FillRect
    add si, 2
    dec cx
    jnz init_draw_snake

; -------------------------------------------------------------------------
; GAME LOOP
; -------------------------------------------------------------------------
game_loop:
    ; -- A. INPUT --
    mov ah, 01h      ; BIOS check keystroke buffer
    int 16h
    jz short no_input
    jmp process_input

no_input:
    jmp do_tick_check

process_input:
    mov ah, 00h      ; Get the actual keystroke
    int 16h
    
    cmp al, ESC_KEY  ; Check if it was the Escape key
    jne check_key_up
    jmp exit_game

check_key_up:
    cmp ah, KEY_UP
    jne check_key_down
    cmp word ptr [dir_y], SEG_SIZE ; Prevent instant reverse into body
    je short input_done
    mov word ptr [next_dir_x], 0
    mov word ptr [next_dir_y], -SEG_SIZE
    jmp short input_done

check_key_down:
    cmp ah, KEY_DOWN
    jne check_key_left
    cmp word ptr [dir_y], -SEG_SIZE
    je short input_done
    mov word ptr [next_dir_x], 0
    mov word ptr [next_dir_y], SEG_SIZE
    jmp short input_done

check_key_left:
    cmp ah, KEY_LEFT
    jne check_key_right
    cmp word ptr [dir_x], SEG_SIZE
    je short input_done
    mov word ptr [next_dir_x], -SEG_SIZE
    mov word ptr [next_dir_y], 0
    jmp short input_done

check_key_right:
    cmp ah, KEY_RIGHT
    jne short input_done
    cmp word ptr [dir_x], -SEG_SIZE
    je short input_done
    mov word ptr [next_dir_x], SEG_SIZE
    mov word ptr [next_dir_y], 0

input_done:
do_tick_check:
    ; -- B. GAME TICK / MOVEMENT UPDATE --
    dec byte ptr [tick_counter]
    jnz short skip_tick
    jmp do_tick_update

skip_tick:
    jmp render_sync

do_tick_update:
    mov byte ptr [tick_counter], 12  ; Slower speed (moves every 12 frames)

    ; Apply queued direction change
    mov ax, [next_dir_x]
    mov [dir_x], ax
    mov ax, [next_dir_y]
    mov [dir_y], ax

    ; Save current tail coordinates for erasure
    mov bx, [snake_len]
    dec bx
    shl bx, 1
    mov ax, [snake_x + bx]
    mov [old_tail_x], ax
    mov ax, [snake_y + bx]
    mov [old_tail_y], ax

    ; Shift body segments from tail to head
    mov cx, [snake_len]
    dec cx
    jz short update_head
    mov si, cx
    shl si, 1
shift_loop:
    mov ax, [snake_x - 2 + si]
    mov [snake_x + si], ax
    mov ax, [snake_y - 2 + si]
    mov [snake_y + si], ax
    sub si, 2
    jnz short shift_loop

update_head:
    ; Move head position
    mov ax, [snake_x]
    add ax, [dir_x]
    mov [snake_x], ax

    mov ax, [snake_y]
    add ax, [dir_y]
    mov [snake_y], ax

    ; -- C. SCREEN WRAP-AROUND & COLLISION DETECTION --
    ; X-axis boundary wrap check
    mov ax, [snake_x]
    cmp ax, 0
    jge check_right_bound
    mov ax, 320 - SEG_SIZE
    mov [snake_x], ax
    jmp short check_y_bounds
check_right_bound:
    cmp ax, 320
    jl short check_y_bounds
    xor ax, ax
    mov [snake_x], ax

check_y_bounds:
    ; Y-axis boundary wrap check
    mov ax, [snake_y]
    cmp ax, 0
    jge check_bottom_bound
    mov ax, 200 - SEG_SIZE
    mov [snake_y], ax
    jmp short check_self_collision
check_bottom_bound:
    cmp ax, 200
    jl short check_self_collision
    xor ax, ax
    mov [snake_y], ax

check_self_collision:
    ; Self collision check (Head vs Body)
    mov cx, [snake_len]
    cmp cx, 1
    jg do_self_checks
    jmp check_food_collision

do_self_checks:
    mov si, 2
self_collision_loop:
    mov ax, [snake_x]
    cmp ax, [snake_x + si]
    jne short next_self_check
    mov ax, [snake_y]
    cmp ax, [snake_y + si]
    je short call_exit_game

next_self_check:
    add si, 2
    dec cx
    cmp cx, 1
    jg short self_collision_loop
    jmp short check_food_collision

call_exit_game:
    jmp exit_game

check_food_collision:
    ; Food collision check (Head vs Food)
    mov ax, [snake_x]
    cmp ax, [food_x]
    jne short process_movement_label
    mov ax, [snake_y]
    cmp ax, [food_y]
    je short call_do_grow
    jmp short process_movement_label

call_do_grow:
    jmp do_grow

process_movement_label:
    jmp process_movement

do_grow:
    mov ax, [snake_len]
    cmp ax, MAX_SNAKE_LEN
    jge short skip_grow_max
    inc word ptr [snake_len]
    
    ; Restore old tail at the newly expanded tail position so tail stays put during growth
    mov bx, [snake_len]
    dec bx
    shl bx, 1
    mov ax, [old_tail_x]
    mov [snake_x + bx], ax
    mov ax, [old_tail_y]
    mov [snake_y + bx], ax
skip_grow_max:
    call spawn_food

    ; Draw new food
    mov ax, 3
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, [food_y]
    push ax
    mov ax, [food_x]
    push ax
    call FillRect

    ; Draw new head
    mov ax, 5
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, [snake_y]
    push ax
    mov ax, [snake_x]
    push ax
    call FillRect

    jmp short render_sync

process_movement:
    ; 1. Erase old tail (Color 0 - Black)
    xor ax, ax
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, [old_tail_y]
    push ax
    mov ax, [old_tail_x]
    push ax
    call FillRect

    ; 2. Draw new head (Color 5 - Light Green)
    mov ax, 5
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, [snake_y]
    push ax
    mov ax, [snake_x]
    push ax
    call FillRect

render_sync:
    call WaitVRT
    jmp game_loop

; -------------------------------------------------------------------------
; EXIT
; -------------------------------------------------------------------------
exit_game:
    mov ax, TEXTMODE
    int 10h
    mov ax, 4C00h
    int 21h

; -------------------------------------------------------------------------
; PROCEDURES
; -------------------------------------------------------------------------

spawn_food proc
    push ax
    push bx
    push cx
    push dx
    push si

generate_food_loop:
    mov ax, 64
    push ax
    call Rand
    mov bx, SEG_SIZE
    mul bx
    mov [food_x], ax

    mov ax, 40
    push ax
    call Rand
    mov bx, SEG_SIZE
    mul bx
    mov [food_y], ax

    mov cx, [snake_len]
    xor si, si
check_overlap:
    mov ax, [snake_x + si]
    cmp ax, [food_x]
    jne short next_overlap
    mov ax, [snake_y + si]
    cmp ax, [food_y]
    je generate_food_loop
next_overlap:
    add si, 2
    dec cx
    jnz short check_overlap

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
spawn_food endp

SetMode proc
    int 10h
    ret
SetMode endp

SRand proc
    push bp
    mov bp, sp
    push ax
    mov ax, [bp+4]
    mov [rand_seed], ax
    pop ax
    pop bp
    ret 2
SRand endp

Rand proc
    push bp
    mov bp, sp
    push bx
    push dx

    mov ax, [rand_seed]
    mov bx, 25173
    mul bx
    add ax, 13849
    mov [rand_seed], ax

    mov bx, [bp+4]
    mul bx
    mov ax, dx

    pop dx
    pop bx
    pop bp
    ret 2
Rand endp

LoadSweetie16 proc
    mov dx, 03C8h
    xor al, al
    out dx, al

    mov dx, 03C9h
    lea si, pal_sweetie16
    mov cx, 48
pal_loop:
    lodsb
    out dx, al
    loop pal_loop
    ret
LoadSweetie16 endp

; Draws a filled rectangle directly to VGA video memory (0A000h).
; Stack parameters: [bp+12]=C, [bp+10]=H, [bp+8]=W, [bp+6]=Y, [bp+4]=X
FillRect proc
    push bp
    mov bp, sp
    push es
    push di
    push ax
    push cx
    push dx

    mov ax, 0A000h
    mov es, ax

    mov ax, [bp+6]     ; Y
    mov dx, ax
    mov ah, al
    xor al, al
    mov cl, 6
    shl dx, cl
    add ax, dx
    add ax, [bp+4]     ; X
    mov di, ax

    mov dx, [bp+10]    ; Height
    mov al, [bp+12]    ; Color
    mov ah, al

row_loop:
    mov cx, [bp+8]     ; Width
    shr cx, 1
    push di

    rep stosw

    jnc short skip_odd
    stosb
skip_odd:
    pop di
    add di, 320
    dec dx
    jnz short row_loop

    pop dx
    pop cx
    pop ax
    pop di
    pop es
    pop bp
    ret 10
FillRect endp

WaitVRT proc
    push dx
    push ax
    mov dx, 03DAh
vert_wait:
    in al, dx
    test al, 08h
    jz short vert_wait
    pop ax
    pop dx
    ret
WaitVRT endp

; -------------------------------------------------------------------------
; DATA
; -------------------------------------------------------------------------
    rand_seed       dw 1
    
    snake_len       dw 3
    snake_x         dw MAX_SNAKE_LEN dup(0)
    snake_y         dw MAX_SNAKE_LEN dup(0)
    
    dir_x           dw SEG_SIZE   ; Start moving right
    dir_y           dw 0
    next_dir_x      dw SEG_SIZE
    next_dir_y      dw 0
    
    food_x          dw 0
    food_y          dw 0
    
    old_tail_x      dw 0
    old_tail_y      dw 0
    
    tick_counter    db 12

    pal_sweetie16 label byte
        db 6,7,11      ; 0: Dark Blue/Black
        db 23,9,23     ; 1: Purple
        db 44,15,20    ; 2: Red
        db 59,31,21    ; 3: Orange
        db 63,51,29    ; 4: Yellow
        db 41,60,28    ; 5: Light Green
        db 14,45,25    ; 6: Medium Green
        db 9,28,30     ; 7: Dark Green/Teal
        db 10,13,27    ; 8: Dark Blue
        db 14,23,50    ; 9: Blue
        db 16,41,61    ; 10: Light Blue
        db 28,59,61    ; 11: Cyan
        db 61,61,61    ; 12: White
        db 37,44,48    ; 13: Light Gray
        db 21,27,33    ; 14: Medium Gray
        db 12,15,21    ; 15: Dark Gray

end start