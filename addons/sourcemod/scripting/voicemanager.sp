#pragma semicolon 1
#pragma newdecls required

#include <voicemanager>
#include <multicolors>
#include <sdktools>
#include <clientprefs>

#define PLUGIN_VERSION "1.0.2"
#define VOICE_MANAGER_PREFIX "{green}[Voice Manager]{default}"

int g_iSelection[MAXPLAYERS+1] = {0};
int g_iCookieSelection[MAXPLAYERS+1] = {-1};
char g_sVolumeLevels[4][2] = { "<<", "<", ">", ">>" };

char g_sDriver[64];

// Cvars
ConVar g_Cvar_VoiceEnable;
ConVar g_Cvar_AllowSelfOverride;

// Cookies
Handle g_Cookie_GlobalOverride;

// Handles
Database g_DB;

public Extension __ext_voicemanager =
{
    name = "VoiceManager",
    file = "voicemanager.ext",
    required = 1,
}

public Plugin myinfo =
{
    name = "[TF2/OF] Voice Manager",
    author = "Fraeven (Extension/Plugin) + Rowedahelicon (Plugin)",
    description = "Plugin for Voice Manager Extension",
    version = PLUGIN_VERSION,
    url = "https://www.scg.wtf"
};

public void OnPluginStart()
{
    g_Cvar_VoiceEnable = FindConVar("vm_enable");
    g_Cvar_AllowSelfOverride = CreateConVar("vm_allow_self", "0", "Allow players to override their own volume (recommended only for testing)");

    RegConsoleCmd("sm_vm", CommandBaseMenu);
    RegConsoleCmd("sm_voicemanager", CommandBaseMenu);
    RegConsoleCmd("sm_vmclear", Command_ClearClientOverrides);

    HookConVarChange(g_Cvar_VoiceEnable, OnVoiceEnableChanged);

    g_Cookie_GlobalOverride = RegClientCookie("voicemanager_cookie", "VM Global Toggle", CookieAccess_Public);

    if (SQL_CheckConfig("voicemanager")) {
        SetFailState("Database config entry 'voicemanager' not found!");
    }

    Database.Connect(SQL_OnDatabaseConnected, "voicemanager");
}

public void SQL_OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        SetFailState("SQL Connection failed! %s", error);
    }

    g_DB = db;
    g_DB.Driver.GetIdentifier(g_sDriver, sizeof(g_sDriver));

    if (!StrEqual(g_sDriver, "sqlite") && !StrEqual(g_sDriver, "mysql"))
    {
        SetFailState("Unsupported database driver %s", g_sDriver);
    }

    // Add voicemanager table if it does not exist
    char query[256];
    g_DB.Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS `voicemanager` (adjuster VARCHAR(64), adjusted VARCHAR(64), level INT, PRIMARY KEY (adjuster, adjusted))");

    g_DB.Query(SQLErrorCheckCallback, query);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsValidClient(client))
        {
            OnClientPostAdminCheck(client);
            OnClientCookiesCached(client);
        }
    }
}

public void OnVoiceEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RefreshActiveOverrides();
}

public void OnClientPostAdminCheck(int client)
{
    if (!g_Cvar_VoiceEnable.BoolValue)
    {
        return;
    }

    char steamid[18];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid))) 
    {
        LogError("Could not retrieve %N's Steam ID, not loading voice overrides.", client);
        return;
    }

    // Load adjustments from database
    char query[256];
    g_DB.Format(query, sizeof(query), "SELECT adjusted, level FROM `voicemanager` WHERE adjuster = '%s'", steamid);
    g_DB.Query(SQL_OnAdjustmentsReceived, query, GetClientUserId(client));
}

public void SQL_OnAdjustmentsReceived(Database db, DBResultSet results, const char[] error, int userid)
{
    if (db == null || error[0] != '\0')
    {
        LogError("[VoiceManager] Failed to load adjustments: %s", error);
        return;
    }

    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client))
    {
        return;
    }

    while (results.FetchRow())
    {
        char steamid[18];
        results.FetchString(0, steamid, sizeof(steamid));
        int level = results.FetchInt(1);
        LoadPlayerAdjustment(client, steamid, level);
    }

    RefreshActiveOverrides();
}

public void OnClientCookiesCached(int client)
{
    char cookie[12];
    GetClientCookie(client, g_Cookie_GlobalOverride, cookie, sizeof(cookie));

    // This is because cookies default to empty and otherwise we use 0 as our lowest volume setting
    if (cookie[0] != '\0')
    {
        int cookieValue = StringToInt(cookie);
        g_iCookieSelection[client] = cookieValue;
        OnPlayerGlobalAdjust(client, cookieValue);
    }
    else
    {
        g_iCookieSelection[client] = -1;
    }
}

public void OnClientDisconnect(int client)
{
    if (g_Cvar_VoiceEnable.BoolValue)
    {
        RefreshActiveOverrides();
    }
}

// Menus
public Action CommandBaseMenu(int client, int args)
{
    if (!g_Cvar_VoiceEnable.BoolValue)
    {
        return Plugin_Handled;
    }

    char playerBuffer[32];
    char stringBuffer[32];
    int playersAdjusted = 0;

    for (int otherClient = 1; otherClient <= MaxClients; otherClient++)
    {
        if (IsValidClient(otherClient) && (g_Cvar_AllowSelfOverride.BoolValue || otherClient != client) && !IsFakeClient(otherClient) && GetClientOverride(client, otherClient) >= 0)
        {
            playersAdjusted++;
        }
    }

    Format(playerBuffer, sizeof(playerBuffer), "Player Adjustment (%i active)", playersAdjusted);

    if (g_iCookieSelection[client] >= 0)
    {
        Format(stringBuffer, sizeof(stringBuffer), "Global Adjustment (%s)", g_sVolumeLevels[g_iCookieSelection[client]]);
    }
    else
    {
        Format(stringBuffer, sizeof(stringBuffer), "Global Adjustment");
    }

    Menu menu = new Menu(BaseMenuHandler);
    menu.SetTitle("Voice Manager");
    menu.AddItem("players", playerBuffer);
    menu.AddItem("global", stringBuffer);
    menu.AddItem("clear", "Clear Player Adjustments");
    menu.ExitButton = true;
    menu.Display(client, 20);

    return Plugin_Handled;
}

public int BaseMenuHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        bool found = menu.GetItem(param2, info, sizeof(info));

        if (found)
        {
            if (StrEqual(info, "players"))
            {
                Menu players = new Menu(VoiceMenuHandler);
                players.SetTitle("Player Voice Manager");

                char id[4];
                char name[32];

                for (int otherClient = 1; otherClient <= MaxClients; otherClient++)
                {
                    if (IsValidClient(otherClient) && (g_Cvar_AllowSelfOverride.BoolValue || otherClient != client) && !IsFakeClient(otherClient))
                    {
                        int override = GetClientOverride(client, otherClient);

                        if (override >= 0)
                        {
                            Format(name, sizeof(name), "%N (%s)", otherClient, g_sVolumeLevels[override]);
                        }
                        else
                        {
                            Format(name, sizeof(name), "%N", otherClient);
                        }
                        IntToString(otherClient, id, sizeof(id));
                        players.AddItem(id, name);
                    }
                }

                if (players.ItemCount == 0)
                {
                    CPrintToChat(client, "%s There are no players to adjust.", VOICE_MANAGER_PREFIX);
                    return 0;
                }

                players.ExitButton = true;
                players.ExitBackButton = true;
                players.Display(client, 20);
            }
            else if (StrEqual(info, "global"))
            {
                Menu global = new Menu(GlobalVoiceVolumeHandler);

                global.SetTitle("Adjust global volume level");
                global.AddItem("3", g_iCookieSelection[client] == 3 ? "Louder *" : "Louder");
                global.AddItem("2", g_iCookieSelection[client] == 2 ? "Loud *" : "Loud");
                global.AddItem("-1", g_iCookieSelection[client] == -1 ? "Normal *" : "Normal");
                global.AddItem("1", g_iCookieSelection[client] == 1 ? "Quiet *" : "Quiet");
                global.AddItem("0", g_iCookieSelection[client] == 0 ? "Quieter *" : "Quieter");

                global.ExitButton = true;
                global.ExitBackButton = true;
                global.Display(client, 20);
            }
            else if (StrEqual(info, "clear"))
            {
                Menu clear = new Menu(ClearMenuHandler);

                clear.SetTitle("Remove all player volume adjustments?");
                clear.AddItem("1", "Yes");
                clear.AddItem("0", "No");

                clear.ExitButton = true;
                clear.Display(client, 20);
            }
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            CommandBaseMenu(client, 0);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public Action Command_ClearClientOverrides(int client, int args)
{
    if (!g_Cvar_VoiceEnable.BoolValue)
    {
        return Plugin_Handled;
    }

    char steamid[18];
    GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));

    char szQuery[511];
    FormatEx(szQuery, sizeof(szQuery), "DELETE FROM `voicemanager` WHERE adjuster = '%s'", steamid);
    SQL_TQuery(g_DB, SQLErrorCheckCallback, szQuery);

    ClearClientOverrides(client);

    CPrintToChat(client, "%s You have cleared all of your voice overrides!", VOICE_MANAGER_PREFIX);

    return Plugin_Handled;

}

public void OnClearClientOverrides(int client)
{
    char steamid[18];
    GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));

    char szQuery[511];
    FormatEx(szQuery, sizeof(szQuery), "DELETE FROM `voicemanager` WHERE adjuster = '%s'", steamid);
    SQL_TQuery(g_DB, SQLErrorCheckCallback, szQuery);

    ClearClientOverrides(client);

    CPrintToChat(client, "%s You have cleared all of your voice overrides!", VOICE_MANAGER_PREFIX);
}

//Handlers
public int VoiceMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        bool found = menu.GetItem(param2, info, sizeof(info));
        if (found)
        {
            int otherClient = StringToInt(info);
            int override = GetClientOverride(param1, otherClient);

            g_iSelection[param1] = otherClient;

            Menu sub_menu = new Menu(VoiceVolumeHandler);

            sub_menu.SetTitle("Adjust %N's volume level", otherClient);
            sub_menu.AddItem("3", override == 3 ? "Louder *" : "Louder");
            sub_menu.AddItem("2", override == 2 ? "Loud *" : "Loud");
            sub_menu.AddItem("-1", override == -1 ? "Normal *" : "Normal");
            sub_menu.AddItem("1", override == 1 ? "Quiet *" : "Quiet");
            sub_menu.AddItem("0", override == 0 ? "Quieter *" : "Quieter");

            sub_menu.ExitButton = true;
            sub_menu.ExitBackButton = true;
            sub_menu.Display(param1, 20);
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            CommandBaseMenu(param1, 0);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public int ClearMenuHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));
        int yes = StringToInt(info);
        if (yes)
        {
            OnClearClientOverrides(client);
        }
        else
        {
            CommandBaseMenu(client, 0);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public int VoiceVolumeHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        char setting[32];
        bool found = menu.GetItem(param2, info, sizeof(info), _, setting, sizeof(setting));
        if (found)
        {
            int level = StringToInt(info);
            if (!OnPlayerAdjustVolume(client, g_iSelection[client], level))
            {
                CPrintToChat(client, "%s Something went wrong, please try again soon!", VOICE_MANAGER_PREFIX);
            }
            else
            {
                CPrintToChat(client, "%s %N's level is now set to %s.", VOICE_MANAGER_PREFIX, g_iSelection[client], setting);
            }

            char adjuster[18], adjusted[18];
            GetClientAuthId(client, AuthId_SteamID64, adjuster, sizeof(adjuster));
            GetClientAuthId(client, AuthId_SteamID64, adjusted, sizeof(adjusted));

            char szQuery[511];
            if (level == -1)
            {
                FormatEx(szQuery, sizeof(szQuery), "DELETE FROM `voicemanager` WHERE adjuster = '%s' AND adjusted = '%s'", adjuster, adjusted);
                SQL_TQuery(g_DB, SQLErrorCheckCallback, szQuery);
            }
            else
            {
                char driver[64];
                SQL_ReadDriver(g_DB, driver, sizeof(driver));

                if (StrEqual(driver, "sqlite"))
                {
                    FormatEx(szQuery, sizeof(szQuery), "\
                        INSERT INTO `voicemanager` (adjuster, adjusted, level)\
                        VALUES ('%s', '%s', %d)\
                        ON CONFLICT(adjuster, adjusted) DO UPDATE SET level = %d",
                    adjuster, adjusted, level, level);
                }
                else
                {
                    FormatEx(szQuery, sizeof(szQuery), "\
                        INSERT INTO `voicemanager` (adjuster, adjusted, level)\
                        VALUES ('%s', '%s', %d)\
                        ON DUPLICATE KEY UPDATE level = %d",
                    adjuster, adjusted, level, level);
                }

                SQL_TQuery(g_DB, SQLErrorCheckCallback, szQuery);
            }
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public void SQLErrorCheckCallback(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == INVALID_HANDLE || strlen(error) > 1)
    {
        LogError("[VoiceManager] SQL Error: %s", error);
    }
}

public int GlobalVoiceVolumeHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        char setting[32];
        bool found = menu.GetItem(param2, info, sizeof(info), _, setting, sizeof(setting));
        if (found)
        {
            int volume = StringToInt(info);
            if (!OnPlayerGlobalAdjust(client, volume))
            {
                CPrintToChat(client, "%s Something went wrong, please try again soon!", VOICE_MANAGER_PREFIX);
            }
            else
            {
                CPrintToChat(client, "%s Global voice volume is now set to %s.", VOICE_MANAGER_PREFIX, setting);
                SetClientCookie(client, g_Cookie_GlobalOverride, info);
                g_iCookieSelection[client] = volume;
            }
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            CommandBaseMenu(client, 0);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

stock bool IsValidClient(int client)
{
    if (!client || client > MaxClients || client < 1 || !IsClientInGame(client))
    {
        return false;
    }

    return true;
}