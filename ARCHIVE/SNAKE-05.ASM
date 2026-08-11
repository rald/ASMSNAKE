.8086                ; Enforce strict 16-bit 8086 instructions
.model tiny          ; Tiny model combines code/data into one segment for .COM
.code
org 100h             ; COM files must start at memory offset 100h

; -------------------------------------------------------------------------
; CONSTANTS
; -------------------------------------------------------------------------
VGAMODE13 EQU 0013h
TEXTMODE  EQU 0003h

; -------------------------------------------------------------------------
; ENTRY POINT
; -------------------------------------------------------------------------
start:
    ; 1. Free up unused memory so we can allocate our double buffer
    mov sp, 0FFFEh   ; Ensure stack is safely at the top of our 64KB segment
    mov ah, 4Ah      ; DOS: Modify memory allocation
    mov bx, 1000h    ; Keep 4096 paragraphs (64KB) for this .COM file
    int 21h

    ; 2. Allocate the Back Buffer (64,000 bytes)
    mov ah, 48h      ; DOS: Allocate memory
    mov bx, 0FA0h    ; 4000 paragraphs = 64,000 bytes (320 * 200)
    int 21h
    mov [buffer_seg], ax ; Save the segment address returned by DOS

    ; 3. Hook Keyboard Interrupt (INT 09h) for simultaneous key tracking
    mov ah, 35h      ; DOS: Get Interrupt Vector
    mov al, 09h
    int 21h
    mov word ptr [old_int09], bx
    mov word ptr [old_int09+2], es

    mov ah, 25h      ; DOS: Set Interrupt Vector
    mov al, 09h
    mov dx, offset new_int09
    int 21h

    ; 4. Set Mode 13h (320x200, 256 colors)
    mov ax, VGAMODE13
    call SetMode

    ; 5. Load the Sweetie-16 Palette
    call LoadSweetie16

; -------------------------------------------------------------------------
; GAME LOOP
; -------------------------------------------------------------------------
game_loop:
    ; -- A. INPUT STATE CHECK --
    cmp byte ptr [esc_pressed], 1
    jne check_up_state
    jmp near ptr exit_game     ; Exit if ESC is held (using near jump to fix range)

check_up_state:
    ; Check Up Arrow State
    cmp byte ptr [key_up_state], 1
    jne check_down_state
    mov ax, [box_y]
    sub ax, 4        ; Move up by 4 pixels
    js check_down_state
    mov [box_y], ax

check_down_state:
    ; Check Down Arrow State
    cmp byte ptr [key_down_state], 1
    jne check_left_state
    mov ax, [box_y]
    add ax, 4        ; Move down by 4 pixels
    cmp ax, 180      ; Bottom boundary (200 - 20 box height)
    jg check_left_state
    mov [box_y], ax

check_left_state:
    ; Check Left Arrow State
    cmp byte ptr [key_left_state], 1
    jne check_right_state
    mov ax, [box_x]
    sub ax, 4        ; Move left by 4 pixels
    js check_right_state
    mov [box_x], ax

check_right_state:
    ; Check Right Arrow State
    cmp byte ptr [key_right_state], 1
    jne render
    mov ax, [box_x]
    add ax, 4        ; Move right by 4 pixels
    cmp ax, 300      ; Right boundary (320 - 20 box width)
    jg render
    mov [box_x], ax

render:
    ; -- B. RENDER (To Back Buffer) --
    
    ; 1. Clear the back buffer (Dark Gray - Index 15)
    mov ax, 15
    push ax          ; C
    mov ax, 200
    push ax          ; H
    mov ax, 320
    push ax          ; W
    xor ax, ax       ; Fast 0
    push ax          ; Y
    push ax          ; X
    call FillRect

    ; 2. Draw the box at its updated coordinates (Yellow - Index 4)
    mov ax, 4
    push ax          ; C
    mov ax, 20
    push ax          ; H
    push ax          ; W (Also 20)
    mov ax, [box_y]
    push ax          ; Y
    mov ax, [box_x]
    push ax          ; X
    call FillRect

    ; 3. Copy the Back Buffer to the VGA Screen
    call FlipBuffer

    ; -- C. DELAY --
    ; Delay for 16 milliseconds (~60 frames per second)
    mov ax, 16
    push ax
    call Delay

    ; Loop back to the start
    jmp game_loop

; -------------------------------------------------------------------------
; EXIT
; -------------------------------------------------------------------------
exit_game:
    ; Restore original Keyboard Interrupt Vector
    mov ah, 25h
    mov al, 09h
    lds dx, [old_int09]
    int 21h

    ; Restore normal text mode before exiting
    mov ax, TEXTMODE
    call SetMode

    ; Exit to DOS
    mov ax, 4C00h
    int 21h

; -------------------------------------------------------------------------
; CUSTOM KEYBOARD INTERRUPT HOOK (INT 09h)
; Tracks simultaneous key presses and releases directly from port 60h
; -------------------------------------------------------------------------
new_int09 proc
    push ax
    push ds

    push cs
    pop ds

    in al, 60h       ; Read hardware scancode from keyboard controller

    cmp al, 0E0h     ; Check for extended key prefix
    jne check_scancode
    mov byte ptr [ext_flag], 1
    jmp int09_ack

check_scancode:
    cmp byte ptr [ext_flag], 1
    je handle_extended

    ; Standard scancodes (e.g. ESC key)
    cmp al, 01h      ; ESC make
    je press_esc
    cmp al, 81h      ; ESC break
    je release_esc
    jmp int09_ack

press_esc:
    mov byte ptr [esc_pressed], 1
    jmp int09_ack
release_esc:
    mov byte ptr [esc_pressed], 0
    jmp int09_ack

handle_extended:
    mov byte ptr [ext_flag], 0 ; Clear extended prefix flag

    cmp al, 48h      ; Up Make
    je p_up
    cmp al, 0C8h     ; Up Break (fixed with leading zero)
    je r_up
    cmp al, 50h      ; Down Make
    je p_down
    cmp al, 0D0h     ; Down Break (fixed with leading zero)
    je r_down
    cmp al, 4Bh      ; Left Make
    je p_left
    cmp al, 0CBh     ; Left Break (fixed with leading zero)
    je r_left
    cmp al, 4Dh      ; Right Make
    je p_right
    cmp al, 0CDh     ; Right Break (fixed with leading zero)
    je r_right
    jmp int09_ack

p_up:    mov byte ptr [key_up_state], 1
         jmp int09_ack
r_up:    mov byte ptr [key_up_state], 0
         jmp int09_ack
p_down:  mov byte ptr [key_down_state], 1
         jmp int09_ack
r_down:  mov byte ptr [key_down_state], 0
         jmp int09_ack
p_left:  mov byte ptr [key_left_state], 1
         jmp int09_ack
r_left:  mov byte ptr [key_left_state], 0
         jmp int09_ack
p_right: mov byte ptr [key_right_state], 1
         jmp int09_ack
r_right: mov byte ptr [key_right_state], 0
         jmp int09_ack

int09_ack:
    ; Acknowledge hardware interrupt to PIC (End of Interrupt)
    mov al, 20h
    out 20h, al

    pop ds
    pop ax
    iret
new_int09 endp

; -------------------------------------------------------------------------
; PROCEDURES
; -------------------------------------------------------------------------

; Sets the video mode. Expects the mode number in the AX register.
SetMode proc
    int 10h
    ret
SetMode endp

; Loads the 16-color custom palette into the VGA DAC.
LoadSweetie16 proc
    mov dx, 03C8h
    xor al, al
    out dx, al

    mov dx, 03C9h
    lea si, pal_sweetie16
    mov cx, 48         ; 16 colors * 3 bytes
pal_loop:
    lodsb
    out dx, al
    loop pal_loop
    ret
LoadSweetie16 endp

; Draws a filled rectangle to the Back Buffer memory segment.
; Optimized to use Shift/Add math and 16-bit word writes.
; Stack parameters: [bp+12]=C, [bp+10]=H, [bp+8]=W, [bp+6]=Y, [bp+4]=X
FillRect proc
    push bp
    mov bp, sp
    push es
    push di
    push ax
    push cx
    push dx

    ; Point ES to the Back Buffer segment
    mov ax, [cs:buffer_seg]
    mov es, ax

    ; ---------------------------------------------------------
    ; FAST MATH: (Y * 320) + X 
    ; 320 = 256 + 64. We calculate (Y*256) + (Y*64) using shifts
    ; ---------------------------------------------------------
    mov ax, [bp+6]     ; Load Y
    mov dx, ax         ; Copy Y to DX
    mov ah, al         ; Instantly multiply AX by 256 (shift left 8)
    xor al, al         ; Clear lower byte so AX = Y * 256
    
    mov cl, 6
    shl dx, cl         ; DX = Y * 64
    
    add ax, dx         ; AX = (Y * 256) + (Y * 64) = Y * 320
    add ax, [bp+4]     ; AX = (Y * 320) + X
    mov di, ax         ; ES:DI points to the starting pixel

    mov dx, [bp+10]    ; DX = Height (Row counter)
    
    mov al, [bp+12]    ; AL = Color Index
    mov ah, al         ; Duplicate color into AH so AX = Color|Color
                       ; This allows us to write 2 pixels per instruction!

row_loop:
    mov cx, [bp+8]     ; CX = Width
    shr cx, 1          ; Divide Width by 2 to count words instead of bytes
    push di            ; Save starting position of current row

    rep stosw          ; OPTIMIZATION: Write 2 pixels per cycle

    jnc skip_odd       ; If the carry flag isn't set, width was even.
    stosb              ; If width was odd, write the 1 leftover pixel.
skip_odd:
    pop di             ; Restore starting position
    add di, 320        ; Move DI down to the next row
    dec dx             ; Decrement Height counter
    jnz row_loop       ; If Height > 0, repeat

    pop dx
    pop cx
    pop ax
    pop di
    pop es
    pop bp
    ret 10             ; Clean up 10 bytes (5 parameters * 2 bytes)
FillRect endp

; Instantly copies the 64,000-byte Back Buffer to the VGA Video Memory
FlipBuffer proc
    push ds
    push es
    push si
    push di
    push cx
    push ax

    ; Source: Back Buffer segment
    mov ax, [cs:buffer_seg]
    mov ds, ax
    xor si, si         ; SI = 0 (Start of buffer)

    ; Destination: VGA Video Memory segment
    mov ax, 0A000h
    mov es, ax
    xor di, di         ; DI = 0 (Start of screen)

    ; Copy 32,000 words (64,000 bytes). 'rep movsw' is the fastest copy instruction
    mov cx, 32000
    rep movsw

    pop ax
    pop cx
    pop di
    pop si
    pop es
    pop ds
    ret
FlipBuffer endp

; Delays execution for a specified number of milliseconds.
; Stack parameters: [bp+4]=Milliseconds
Delay proc
    push bp
    mov bp, sp
    push ax
    push bx
    push cx
    push dx

    ; BIOS Wait requires microseconds in CX:DX
    mov ax, [bp+4]     ; Load Milliseconds
    mov bx, 1000
    mul bx             ; DX:AX = Milliseconds * 1000

    mov cx, dx         ; CX = High word of microseconds
    mov dx, ax         ; DX = Low word of microseconds
    
    mov ah, 86h        ; BIOS Wait function
    int 15h

    pop dx
    pop cx
    pop bx
    pop ax
    pop bp
    ret 2              ; Clean up 2 bytes
Delay endp

; -------------------------------------------------------------------------
; DATA
; -------------------------------------------------------------------------
    buffer_seg      dw 0    ; Stores the dynamically allocated RAM segment
    box_x           dw 150  ; Starting X position
    box_y           dw 90   ; Starting Y position
    old_int09       dd 0    ; Storage for original INT 09h vector
    ext_flag        db 0    ; Extended scan code prefix flag (0E0h)
    key_up_state    db 0    ; 1 if Up arrow is held, 0 otherwise
    key_down_state  db 0    ; 1 if Down arrow is held, 0 otherwise
    key_left_state  db 0    ; 1 if Left arrow is held, 0 otherwise
    key_right_state db 0    ; 1 if Right arrow is held, 0 otherwise
    esc_pressed     db 0    ; 1 if ESC is held, 0 otherwise

    ; Palette definition (Sweetie-16)
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