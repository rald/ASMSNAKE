.8086                ; Enforce strict 16-bit 8086 instructions
.model tiny          ; Tiny model combines code/data into one segment for .COM
.code
org 100h             ; COM files must start at memory offset 100h

; -------------------------------------------------------------------------
; CONSTANTS
; -------------------------------------------------------------------------
VGAMODE13 EQU 0013h
TEXTMODE  EQU 0003h
ESC_KEY   EQU 27

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

    ; 3. Set Mode 13h (320x200, 256 colors)
    mov ax, VGAMODE13
    call SetMode

    ; 4. Load the Sweetie-16 Palette
    call LoadSweetie16

; -------------------------------------------------------------------------
; GAME LOOP
; -------------------------------------------------------------------------
game_loop:
    ; -- A. INPUT --
    mov ah, 01h      ; BIOS check keystroke buffer
    int 16h
    jz update_state  ; If zero flag is set, no key pressed
    
    mov ah, 00h      ; Get the actual keystroke
    int 16h
    cmp al, ESC_KEY  ; Check if it was the Escape key
    je exit_game     ; If yes, break the loop and exit

update_state:
    ; -- B. UPDATE --
    ; Move the box X position
    mov ax, [box_x]
    add ax, [box_dir]
    mov [box_x], ax  ; Save new position

    ; Check bounds to bounce off walls
    cmp ax, 300      ; Right edge (320 total width - 20 box width)
    jge reverse_dir
    cmp ax, 0        ; Left edge
    jle reverse_dir
    jmp render

reverse_dir:
    mov ax, [box_dir]
    neg ax           ; Multiply by -1 to reverse direction
    mov [box_dir], ax

render:
    ; -- C. RENDER (To Back Buffer) --
    
    ; 1. Clear the back buffer by drawing a full-screen background (Dark Gray - Index 15)
    mov ax, 15
    push ax          ; C
    mov ax, 200
    push ax          ; H
    mov ax, 320
    push ax          ; W
    mov ax, 0
    push ax          ; Y
    mov ax, 0
    push ax          ; X
    call FillRect

    ; 2. Draw the box at its new position (Yellow - Index 4)
    mov ax, 4
    push ax          ; C
    mov ax, 20
    push ax          ; H
    mov ax, 20
    push ax          ; W
    mov ax, 90
    push ax          ; Y
    mov ax, [box_x]
    push ax          ; X
    call FillRect

    ; 3. Copy the Back Buffer to the VGA Screen
    call FlipBuffer

    ; -- D. DELAY --
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
    ; Restore normal text mode before exiting
    mov ax, TEXTMODE
    call SetMode

    ; Exit to DOS
    mov ax, 4C00h
    int 21h

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
    mov al, 0
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
; Stack parameters: [bp+12]=C, [bp+10]=H, [bp+8]=W, [bp+6]=Y, [bp+4]=X
FillRect proc
    push bp
    mov bp, sp
    push es
    push di
    push ax
    push bx
    push cx
    push dx

    ; Point ES to the Back Buffer segment (instead of A000h)
    mov ax, [cs:buffer_seg]
    mov es, ax

    ; Calculate memory offset: (Y * 320) + X
    mov ax, [bp+6]     ; Load Y
    mov bx, 320
    mul bx             ; DX:AX = Y * 320
    add ax, [bp+4]     ; AX = (Y * 320) + X
    mov di, ax         ; ES:DI now points to the starting pixel

    mov dx, [bp+10]    ; DX = Height (Row counter)
    mov ax, [bp+12]    ; Load Color parameter into AX (Color is in AL)

row_loop:
    mov cx, [bp+8]     ; CX = Width (Pixel counter for 'rep stosb')
    push di            ; Save starting position of current row

    rep stosb          ; Fills CX pixels with color AL

    pop di             ; Restore starting position
    add di, 320        ; Move DI down to the next row
    dec dx             ; Decrement Height counter
    jnz row_loop       ; If Height > 0, repeat

    pop dx
    pop cx
    pop bx
    pop ax
    pop di
    pop es
    pop bp
    ret 10             ; Clean up 10 bytes (5 parameters * 2 bytes each)
FillRect endp

; Copies the entire 64,000-byte Back Buffer to the VGA Video Memory
FlipBuffer proc
    push bp
    mov bp, sp
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

    ; Copy 32,000 words (which equals 64,000 bytes)
    mov cx, 32000
    rep movsw

    pop ax
    pop cx
    pop di
    pop si
    pop es
    pop ds
    pop bp
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
    ; Microseconds = Milliseconds * 1000
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
    ret 2              ; Clean up 2 bytes (1 parameter)
Delay endp

; -------------------------------------------------------------------------
; DATA
; -------------------------------------------------------------------------
    ; Variables
    buffer_seg dw 0    ; Stores the dynamically allocated RAM segment
    box_x      dw 150  ; Starting X position
    box_dir    dw 2    ; Moving 2 pixels at a time

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