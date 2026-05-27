print_int:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    mov ebx, 10
    sub rsp, 32
    mov byte [rsp], 0
    lea rdi, [rsp + 31]
    mov byte [rdi], 10
    dec rdi
    cmp eax, 0
    jge .loop
    neg eax
    mov byte [rsp], 1
.loop:
    xor edx, edx
    div ebx
    add dl, '0'
    mov [rdi], dl
    dec rdi
    test eax, eax
    jnz .loop
    cmp byte [rsp], 1
    jne .write
    mov byte [rdi], '-'
    dec rdi
.write:
    lea rsi, [rdi + 1]
    mov rdx, rsp
    add rdx, 32
    sub rdx, rsi
    mov edi, 1
    mov eax, 1
    syscall
    add rsp, 32
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

atoi:
    push rcx
    xor eax, eax
    xor ecx, ecx
    cmp byte [rdi], '-'
    jne .loop
    mov cl, 1
    inc rdi
.loop:
    movzx edx, byte [rdi]
    test dl, dl
    jz .done
    sub edx, '0'
    cmp edx, 9
    ja .done
    imul eax, 10
    add eax, edx
    inc rdi
    jmp .loop
.done:
    test ecx, ecx
    jz .ret
    neg eax
.ret:
    pop rcx
    ret
