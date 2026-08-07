@{
    Category = 'Setup / Maintenance'
    Label    = 'Clean up user profiles on THIS computer'
    Order    = 82
    # This one DELETES user profiles. Without an Audience the launcher falls
    # back to 'Both', which offered it to every sign-in.
    Audience = 'Admin'
}
