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
    ; 1. Set Mode 13h (320x200, 256 colors)
    mov ax, VGAMODE13
    call SetMode

    ; 2. Load the Sweetie-16 Palette
    call LoadSweetie16

    ; 3. Draw Rectangles by pushing parameters (C, H, W, Y, X) and calling FillRect

    ; Background box: X=0, Y=0, W=320, H=200, C=15 (Dark Gray)
    mov ax, 15
    push ax
    mov ax, 200
    push ax
    mov ax, 320
    push ax
    mov ax, 0
    push ax
    mov ax, 0
    push ax
    call FillRect
    
    ; Main box: X=80, Y=50, W=160, H=100, C=1 (Purple)
    mov ax, 1
    push ax
    mov ax, 100
    push ax
    mov ax, 160
    push ax
    mov ax, 50
    push ax
    mov ax, 80
    push ax
    call FillRect
    
    ; Inner box: X=100, Y=70, W=120, H=60, C=4 (Yellow)
    mov ax, 4
    push ax
    mov ax, 60
    push ax
    mov ax, 120
    push ax
    mov ax, 70
    push ax
    mov ax, 100
    push ax
    call FillRect
    
    ; Center box: X=130, Y=90, W=60, H=20, C=11 (Cyan)
    mov ax, 11
    push ax
    mov ax, 20
    push ax
    mov ax, 60
    push ax
    mov ax, 90
    push ax
    mov ax, 130
    push ax
    call FillRect

    ; Wait for any key press
    mov ah, 00h
    int 16h

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

; Draws a filled rectangle to VGA memory.
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

    ; Point ES to VGA video memory (A000h)
    mov ax, 0A000h
    mov es, ax

    ; Calculate memory offset: (Y * 320) + X
    mov ax, [bp+6]     ; Load Y
    mov bx, 320
    mul bx             ; DX:AX = Y * 320 (Valid on 8086)
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

; -------------------------------------------------------------------------
; DATA
; -------------------------------------------------------------------------
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
