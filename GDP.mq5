//+------------------------------------------------------------------+
//|                                                          GDP.mq5 |
//|                        GDP - Gestionnaire De Positions            |
//|                                                                   |
//|  Calculateur de taille de position + placement d'ordres.          |
//|  Outil autonome de gestion de positions, sans aucune logique      |
//|  de detection ni d'auto-trading.                                  |
//|                                                                   |
//|  Ce que fait l'EA :                                               |
//|    - lit Entry / Stop Loss / Take Profit / Risque %               |
//|    - calcule le lot exact pour le risque choisi (frais inclus)    |
//|    - affiche RR brut, RR net (frais), RR net volatilite           |
//|    - place l'ordre (marche ou pending) d'un clic                  |
//|    - gere les positions ouvertes (BE+, cloture)                   |
//|                                                                   |
//|  Ce que l'EA ne fait PAS :                                        |
//|    - aucune detection de structure, aucun signal, aucune alerte   |
//|    - aucune ouverture de position sans clic du trader             |
//+------------------------------------------------------------------+
#property copyright "Arthur Adoua"
#property version   "1.00"
#property description "GDP - Gestionnaire De Positions : calcul du lot selon le risque, placement d'ordres et gestion des positions ouvertes. Aucun trading automatique."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//+------------------------------------------------------------------+
input group "=== RISQUE & SIZING ==="
input double GDP_RiskPercent          = 0.25;  // Risque par defaut (% du solde)
input bool   GDP_IncludeAllCosts      = true;  // Inclure les frais dans le calcul du lot
input bool   GDP_ShowCalculations     = false; // Logs detailles du calcul (Journal)

input group "=== COMMISSION ==="
input bool   GDP_UseCommission        = true;  // Prendre en compte la commission
input bool   GDP_AutoDetectCommission = false; // Deviner la commission selon le symbole
input double GDP_CommissionPerLot     = 7.0;   // Commission FOREX par lot (aller-retour, $)
input double GDP_CFDCommissionPerLot  = 0.0;   // Commission CFD / Indices par lot ($)

input group "=== VOLATILITE (Vol $ / RR Vol) ==="
input bool   GDP_ShowVolatility       = true;  // Afficher Vol $ et RR Vol
input int    GDP_ATRPeriod            = 14;    // Periode ATR
input double GDP_MaxATRPips           = 50.0;  // Seuil ATR (pips) au-dela duquel on estime du slippage
input double GDP_VolSlippageFactor    = 0.10;  // Slippage estime par pip d'ATR au-dessus du seuil

input group "=== EXECUTION ==="
input long   GDP_MagicNumber          = 26082501; // Magic number des ordres places par le GDP
input bool   GDP_ManageOnlyOwn        = false; // true = ne gerer que les positions du GDP
input int    GDP_Deviation            = 20;    // Deviation max (points) sur ordre au marche

input group "=== BILAN ==="
input int    GDP_DayResetHour         = 0;     // Heure serveur du debut de journee pour le bilan (0-23)

input group "=== JOURNAL DE TRADES ==="
input bool   GDP_JournalEnabled       = true;  // Journaliser les ordres places
input bool   GDP_SnapshotOnOrder      = true;  // Capturer le setup a l'enregistrement
input int    GDP_SnapshotWidth        = 760;   // Largeur du snapshot (pixels)
input int    GDP_SnapshotHeight       = 420;   // Hauteur du snapshot (pixels)
input bool   GDP_SnapshotAsBMP        = true;  // true = BMP relisible dans la revue | false = PNG (leger, hors MT5)
input string GDP_JournalTags          = "Structure,Liquidite,FVG,Order Block,Retest,Session,News,Contre-tendance"; // Motifs cliquables (8 max, virgules)

input group "=== NIVEAUX PAR DEFAUT ==="
input double GDP_DefaultSLPips        = 0.0;   // Distance SL au demarrage (pips, 0 = ATR courant)
input double GDP_DefaultRR            = 3.0;   // TP au demarrage = RR x distance du SL

//--- langues disponibles
enum ENUM_GDP_LANG
{
    GDP_LANG_FR,   // Francais
    GDP_LANG_EN    // English
};

input group "=== INTERFACE ==="
input ENUM_GDP_LANG GDP_Language       = GDP_LANG_FR; // Langue de l'interface / Interface language
input bool   GDP_AdvancedOnStart      = false; // Afficher le detail avance au demarrage
input int    GDP_PanelX               = 20;    // Position X du panneau
input int    GDP_PanelY               = 20;    // Position Y du panneau
input bool   GDP_LinesOnStart         = true;  // Lignes Entry/SL/TP visibles au demarrage

//+------------------------------------------------------------------+
//| LANGUE                                                            |
//+------------------------------------------------------------------+
//  Le texte des deux langues est ecrit au point d'usage : aucune table
//  de cles a maintenir, et il est impossible d'oublier une traduction.
string GDP_T(string fr, string en)
{
    return (GDP_Language == GDP_LANG_EN) ? en : fr;
}

//+------------------------------------------------------------------+
//| PALETTE                                                           |
//+------------------------------------------------------------------+
//  Une seule source pour toutes les couleurs : changer ces valeurs
//  suffit a rehabiller l'ensemble des panneaux.
#define GDP_C_BORDER     C'58,64,82'       // contour des panneaux
#define GDP_C_PANEL      C'32,35,44'       // fond principal
#define GDP_C_PANEL_ALT  C'39,43,54'       // fond des blocs internes
#define GDP_C_TITLE      C'24,26,33'       // barre de titre
#define GDP_C_FIELD      C'46,50,63'       // champs de saisie
#define GDP_C_TEXT       C'232,236,245'    // texte principal
#define GDP_C_TEXT_DIM   C'146,155,175'    // texte secondaire
#define GDP_C_ACCENT     C'64,140,255'     // bleu d'accentuation
#define GDP_C_BUY        C'38,166,109'     // achat
#define GDP_C_SELL       C'224,86,80'      // vente
#define GDP_C_WARN       C'240,181,65'     // attention / mise en avant
#define GDP_C_NEUTRAL    C'70,76,94'       // bouton inactif

//+------------------------------------------------------------------+
//| ETAT GLOBAL                                                       |
//+------------------------------------------------------------------+
CTrade gdp_trade;

//--- prefixes objets
#define GDP_PFX      "GDP_MAIN_"  // panneau principal
#define GDP_POS_PFX  "GDP_POS_"   // panneau positions
#define GDP_BIL_PFX  "GDP_BIL_"   // panneau bilan
#define GDP_JRN_PFX  "GDP_JRN_"   // panneau journal (saisie)
#define GDP_REV_PFX  "GDP_REV_"   // panneau revue (relecture)

//--- emplacement des donnees du journal, sous MQL5\Files
#define GDP_JRN_FOLDER  "GDP_Journal"
#define GDP_JRN_FILE    "GDP_Journal\\journal.csv"
#define GDP_JRN_SNAPDIR "GDP_Journal\\snapshots"

#define GDP_JRN_LINES    3        // champs de saisie libre
#define GDP_JRN_MAX_TAGS 8        // motifs cliquables

//--- une entree du journal, telle qu'elle est lue et affichee (tout en texte)
struct GDP_JournalEntry
{
    string stamp;
    string symbol;
    string direction;
    string order_type;
    string entry;
    string sl;
    string tp;
    string lots;
    string risk;
    string rr;
    string ticket;
    string conf;
    string tags;
    string reason;
    string snap;
};

//--- periodes du bilan
enum ENUM_GDP_PERIOD
{
    GDP_PERIOD_DAY,
    GDP_PERIOD_WEEK,
    GDP_PERIOD_MONTH
};

//--- stats d'un instrument sur la periode
struct GDP_SymStats
{
    string symbol;
    int    wins;
    int    losses;
    int    breakevens;   // P&L exactement nul
    double net_pnl;      // profit + commission + swap
};

//--- noms des lignes de prix
#define GDP_LINE_ENTRY   "GDP_LINE_Entry"
#define GDP_LINE_PENDING "GDP_LINE_Pending"
#define GDP_LINE_SL      "GDP_LINE_SL"
#define GDP_LINE_TP      "GDP_LINE_TP"

//--- valeurs de trading
double gdp_entry_price   = 0.0;
double gdp_pending_price = 0.0;
double gdp_stop_loss     = 0.0;
double gdp_take_profit   = 0.0;
double gdp_risk_percent  = 0.25;
double gdp_lots          = 0.0;

//--- modes
bool            gdp_pending_mode  = false;
ENUM_ORDER_TYPE gdp_pending_type  = ORDER_TYPE_BUY_LIMIT;
bool            gdp_lines_visible = true;

//--- panneau principal
bool gdp_panel_visible   = true;
bool gdp_panel_minimized = false;
bool gdp_advanced        = false;   // bloc "detail avance" deplie
int  gdp_panel_x         = 20;
int  gdp_panel_y         = 20;
int  gdp_panel_width     = 380;
int  gdp_panel_h_min     = 25;
bool gdp_panel_dragging  = false;
int  gdp_drag_off_x      = 0;
int  gdp_drag_off_y      = 0;

//--- panneau positions
bool  gdp_pos_visible    = false;
int   gdp_pos_x          = 410;
int   gdp_pos_y          = 20;
int   gdp_pos_width      = 380;
int   gdp_pos_height     = 300;
bool  gdp_pos_dragging   = false;
int   gdp_pos_drag_off_x = 0;
int   gdp_pos_drag_off_y = 0;
ulong gdp_pos_tickets[];  // tickets actuellement affiches

//--- panneau bilan
bool            gdp_bilan_visible   = false;
ENUM_GDP_PERIOD gdp_bilan_period    = GDP_PERIOD_DAY;
int             gdp_bilan_x         = 120;
int             gdp_bilan_y         = 80;
int             gdp_bilan_width     = 470;
bool            gdp_bilan_dragging  = false;
int             gdp_bilan_drag_off_x = 0;
int             gdp_bilan_drag_off_y = 0;
int             gdp_bilan_refresh_countdown = 0;

//--- panneau journal (saisie des raisons)
bool   gdp_jrn_visible    = false;
int    gdp_jrn_x          = 20;
int    gdp_jrn_y          = 460;
int    gdp_jrn_width      = 380;
bool   gdp_jrn_dragging   = false;
int    gdp_jrn_drag_off_x = 0;
int    gdp_jrn_drag_off_y = 0;

string gdp_jrn_reason[GDP_JRN_LINES];   // les 3 lignes de saisie libre
int    gdp_jrn_conf       = 0;          // niveau de confiance 1..5, 0 = non renseigne
bool   gdp_jrn_snap_on    = true;       // capturer le setup au prochain enregistrement

string gdp_jrn_tag_name[];              // motifs issus de GDP_JournalTags
bool   gdp_jrn_tag_on[];                // motifs actuellement selectionnes
int    gdp_jrn_tag_count  = 0;

//--- panneau revue (relecture du journal)
bool  gdp_rev_visible     = false;
int   gdp_rev_x           = 120;
int   gdp_rev_y           = 60;
bool  gdp_rev_dragging    = false;
int   gdp_rev_drag_off_x  = 0;
int   gdp_rev_drag_off_y  = 0;
int   gdp_rev_index       = 0;          // entree affichee
GDP_JournalEntry gdp_rev_entries[];

//--- ligne de statut (remplace les popups Alert)
string gdp_status_text  = "Pret.";
color  gdp_status_color = GDP_C_NEUTRAL;

//--- ATR
int gdp_atr_handle = INVALID_HANDLE;

//--- valeurs derivees, recalculees par GDP_UpdateCalculations()
double gdp_potential_profit = 0.0;
double gdp_potential_loss   = 0.0;
double gdp_total_costs      = 0.0;

//+------------------------------------------------------------------+
//| STATUT (affichage sans popup)                                     |
//+------------------------------------------------------------------+
void GDP_SetStatus(string text, color clr)
{
    gdp_status_text  = text;
    gdp_status_color = clr;
    Print("[GDP] ", text);

    if(ObjectFind(0, GDP_PFX "Status") >= 0)
    {
        ObjectSetString(0, GDP_PFX "Status", OBJPROP_TEXT, text);
        ObjectSetInteger(0, GDP_PFX "Status", OBJPROP_COLOR, clr);
        ChartRedraw();
    }
}

//+------------------------------------------------------------------+
//| PRIMITIVES GRAPHIQUES                                             |
//+------------------------------------------------------------------+
void GDP_CreateLabel(string name, int x, int y, string text, color clr, int font_size)
{
    if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, font_size);
    ObjectSetString(0, name, OBJPROP_FONT, "Arial");
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void GDP_CreateEdit(string name, int x, int y, int width, int height, string text)
{
    if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
    ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, GDP_C_TEXT);
    ObjectSetInteger(0, name, OBJPROP_COLOR, GDP_C_TITLE);
    ObjectSetInteger(0, name, OBJPROP_READONLY, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void GDP_CreateButton(string name, int x, int y, int width, int height, string text, color bg_color)
{
    if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
    ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg_color);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
    ObjectSetInteger(0, name, OBJPROP_COLOR, GDP_C_TITLE);
    ObjectSetInteger(0, name, OBJPROP_STATE, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void GDP_CreateRectangle(string name, int x1, int y1, int x2, int y2, color clr)
{
    if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x1);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y1);
    ObjectSetInteger(0, name, OBJPROP_XSIZE, x2 - x1);
    ObjectSetInteger(0, name, OBJPROP_YSIZE, y2 - y1);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
}

//--- bouton habille : fond plein, texte clair, pas de relief Windows
void GDP_Btn(string name, int x, int y, int width, int height, string text,
             color bg, color fg = GDP_C_TEXT, int font_size = 8)
{
    GDP_CreateButton(name, x, y, width, height, text, bg);
    ObjectSetInteger(0, name, OBJPROP_COLOR, fg);
    ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, bg);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, font_size);
}

//--- champ de saisie habille
void GDP_Field(string name, int x, int y, int width, int height, string text, bool readonly = false)
{
    GDP_CreateEdit(name, x, y, width, height, text);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, readonly ? GDP_C_PANEL_ALT : GDP_C_FIELD);
    ObjectSetInteger(0, name, OBJPROP_COLOR, readonly ? GDP_C_TEXT_DIM : GDP_C_TEXT);
    ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, GDP_C_BORDER);
    ObjectSetInteger(0, name, OBJPROP_ALIGN, ALIGN_LEFT);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
    ObjectSetInteger(0, name, OBJPROP_READONLY, readonly);
}

//--- supprime les objets du panneau principal (jamais les lignes ni le panneau positions)
void GDP_DeletePanelObjects()
{
    for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
    {
        string name = ObjectName(0, i);
        if(StringFind(name, GDP_PFX) == 0)
            ObjectDelete(0, name);
    }
}

void GDP_MoveAllObjects(int delta_x, int delta_y)
{
    for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
    {
        string name = ObjectName(0, i);
        if(StringFind(name, GDP_PFX) != 0) continue;

        int cx = (int)ObjectGetInteger(0, name, OBJPROP_XDISTANCE);
        int cy = (int)ObjectGetInteger(0, name, OBJPROP_YDISTANCE);
        ObjectSetInteger(0, name, OBJPROP_XDISTANCE, cx + delta_x);
        ObjectSetInteger(0, name, OBJPROP_YDISTANCE, cy + delta_y);
    }
}

//+------------------------------------------------------------------+
//| OUTILS SYMBOLE                                                    |
//+------------------------------------------------------------------+
bool GDP_IsCFDSymbol(string symbol)
{
    ENUM_SYMBOL_CALC_MODE calc_mode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_CALC_MODE);

    if(calc_mode == SYMBOL_CALC_MODE_CFD ||
       calc_mode == SYMBOL_CALC_MODE_CFDINDEX ||
       calc_mode == SYMBOL_CALC_MODE_CFDLEVERAGE)
        return true;

    // Les indices ont typiquement <= 2 decimales
    return ((int)SymbolInfoInteger(symbol, SYMBOL_DIGITS) <= 2);
}

double GDP_PipSize(string symbol)
{
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    return (digits == 3 || digits == 5) ? point * 10.0 : point;
}

double GDP_NormalizeLots(double lots, string symbol)
{
    double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double max_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

    if(lot_step <= 0) lot_step = 0.01;

    double norm = MathFloor(lots / lot_step) * lot_step;

    // Nombre de decimales du lot_step, pour eviter 382.18999999
    int lot_digits = 0;
    double temp = lot_step;
    while(MathAbs(temp - MathRound(temp)) > 0.0000001 && lot_digits < 8)
    {
        temp *= 10;
        lot_digits++;
    }
    norm = NormalizeDouble(norm, lot_digits);

    if(norm < min_lot) norm = min_lot;
    if(norm > max_lot) norm = max_lot;
    return norm;
}

double GDP_CalculateRiskReward(double entry, double stop, double take)
{
    double risk = MathAbs(entry - stop);
    if(risk <= 0) return 0.0;
    return MathAbs(take - entry) / risk;
}

//+------------------------------------------------------------------+
//| COMMISSION & FRAIS                                                |
//+------------------------------------------------------------------+
double GDP_GetCommissionPerLot(string symbol)
{
    if(GDP_IsCFDSymbol(symbol))
        return GDP_CFDCommissionPerLot;

    if(GDP_AutoDetectCommission)
    {
        if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
            return 10.0;
        if(StringFind(symbol, "EUR") >= 0 || StringFind(symbol, "USD") >= 0 ||
           StringFind(symbol, "GBP") >= 0 || StringFind(symbol, "JPY") >= 0)
            return 7.0;
    }

    return GDP_CommissionPerLot;
}

//--- Cout total d'un aller-retour : commission + spread
double GDP_CalculateAllCosts(double lots, string symbol)
{
    double total = 0.0;

    if(GDP_UseCommission)
        total += lots * GDP_GetCommissionPerLot(symbol);

    double spread_points = (double)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
    double tick_value    = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size     = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    double point         = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double point_value   = (tick_size != 0) ? (tick_value / tick_size) * point : tick_value;

    // Le spread est traverse dans tous les cas (marche comme pending)
    total += lots * spread_points * point_value;

    return total;
}

//+------------------------------------------------------------------+
//| VOLATILITE                                                        |
//+------------------------------------------------------------------+
double GDP_GetATRPips()
{
    if(gdp_atr_handle == INVALID_HANDLE) return 0.0;

    double buf[];
    if(CopyBuffer(gdp_atr_handle, 0, 0, 1, buf) != 1) return 0.0;

    double pip = GDP_PipSize(_Symbol);
    if(pip <= 0) return 0.0;
    return buf[0] / pip;
}

//--- Slippage estime (pips) lorsque l'ATR depasse le seuil
double GDP_GetVolSlippagePips()
{
    if(!GDP_ShowVolatility) return 0.0;

    double atr_pips = GDP_GetATRPips();
    if(atr_pips <= GDP_MaxATRPips) return 0.0;
    return (atr_pips - GDP_MaxATRPips) * GDP_VolSlippageFactor;
}

//+------------------------------------------------------------------+
//| CALCUL DU LOT - version simple (sans frais)                       |
//+------------------------------------------------------------------+
double GDP_CalculatePositionSize(double entry, double stop, double risk_pct, string symbol)
{
    if(entry <= 0 || stop <= 0 || risk_pct <= 0) return 0.0;

    double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk_money = balance * risk_pct / 100.0;

    double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tick_size <= 0 || tick_value <= 0) return 0.0;

    double distance_ticks = MathAbs(entry - stop) / tick_size;
    if(distance_ticks <= 0) return 0.0;

    double lots = risk_money / (distance_ticks * tick_value);
    return GDP_NormalizeLots(lots, symbol);
}

//+------------------------------------------------------------------+
//| CALCUL DU LOT - frais inclus, convergence iterative               |
//|                                                                   |
//| Le lot influe sur les frais, et les frais reduisent le budget de  |
//| risque disponible : on itere jusqu'a stabilisation, puis on       |
//| verifie que le risque total (SL + frais) ne depasse pas la cible. |
//+------------------------------------------------------------------+
double GDP_CalculatePositionSizeWithAllCosts(double entry, double stop, double risk_pct, string symbol)
{
    if(!GDP_IncludeAllCosts)
        return GDP_CalculatePositionSize(entry, stop, risk_pct, symbol);

    if(entry <= 0 || stop <= 0 || risk_pct <= 0) return 0.0;

    double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk_money = balance * risk_pct / 100.0;

    double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    double min_lot    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double max_lot    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
    double lot_step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

    if(point <= 0 || tick_size <= 0 || tick_value <= 0 || lot_step <= 0) return 0.0;
    if(MathAbs(entry - stop) / point <= 0) return 0.0;

    ENUM_ORDER_TYPE order_type = (entry > stop) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    double distance_ticks = MathAbs(entry - stop) / tick_size;

    if(GDP_ShowCalculations)
    {
        Print("--- GDP calcul du lot ---");
        Print("   Solde       : ", DoubleToString(balance, 2));
        Print("   Risque cible: ", DoubleToString(risk_pct, 2), "% = ", DoubleToString(risk_money, 2));
        Print("   Volume      : min=", DoubleToString(min_lot, 2),
              " max=", DoubleToString(max_lot, 2), " step=", DoubleToString(lot_step, 2));
    }

    double lots      = min_lot;
    double tolerance = lot_step * 0.1;

    for(int it = 0; it < 10; it++)
    {
        double costs     = GDP_CalculateAllCosts(lots, symbol);
        double available = risk_money - costs;

        if(available <= 0)
        {
            // Les frais mangent tout le budget de risque : lot minimum
            lots = min_lot;
            if(GDP_ShowCalculations)
                Print("   Frais (", DoubleToString(costs, 2), ") >= risque (",
                      DoubleToString(risk_money, 2), ") -> lot minimum");
            break;
        }

        // Perte au SL pour le lot courant : on retient le pire des deux methodes
        double loss_ocp = 0.0;
        if(OrderCalcProfit(order_type, symbol, lots, entry, stop, loss_ocp))
            loss_ocp = MathAbs(loss_ocp);
        double loss_manual = lots * distance_ticks * tick_value;
        double loss_eff    = MathMax(loss_ocp, loss_manual);

        double new_lots;
        if(loss_eff > 0)
        {
            double ratio = available / loss_eff;
            if(ratio > 10.0) ratio = 10.0;   // convergence progressive sur les indices
            if(ratio < 0.1)  ratio = 0.1;
            new_lots = lots * ratio;
        }
        else
        {
            new_lots = available / (distance_ticks * tick_value);
        }

        new_lots = MathFloor(new_lots / lot_step) * lot_step;
        if(new_lots < min_lot) new_lots = min_lot;
        if(new_lots > max_lot) new_lots = max_lot;

        if(GDP_ShowCalculations)
            Print("   Iteration ", it + 1, " : lots=", DoubleToString(new_lots, 2),
                  " frais=", DoubleToString(costs, 2),
                  " dispo=", DoubleToString(available, 2),
                  " perte SL=", DoubleToString(loss_eff, 2));

        bool converged = (MathAbs(new_lots - lots) <= tolerance);
        lots = new_lots;
        if(converged) break;
    }

    // Verification finale : risque total (perte au SL + frais) <= cible
    double sl_risk_ocp = 0.0;
    if(OrderCalcProfit(order_type, symbol, lots, entry, stop, sl_risk_ocp))
        sl_risk_ocp = MathAbs(sl_risk_ocp);
    double sl_risk_manual = lots * distance_ticks * tick_value;
    double sl_risk        = MathMax(sl_risk_ocp, sl_risk_manual);

    double total_risk   = sl_risk + GDP_CalculateAllCosts(lots, symbol);
    double real_risk_pc = (balance > 0) ? (total_risk / balance) * 100.0 : 0.0;

    if(real_risk_pc > risk_pct && real_risk_pc > 0)
    {
        double corrected = lots * (risk_pct / real_risk_pc);
        corrected = MathFloor(corrected / lot_step) * lot_step;

        if(corrected >= min_lot)
        {
            double verif_ocp = 0.0;
            if(OrderCalcProfit(order_type, symbol, corrected, entry, stop, verif_ocp))
                verif_ocp = MathAbs(verif_ocp);
            double verif = MathMax(verif_ocp, corrected * distance_ticks * tick_value);
            double verif_pc = ((verif + GDP_CalculateAllCosts(corrected, symbol)) / balance) * 100.0;

            if(verif_pc <= risk_pct)
            {
                if(GDP_ShowCalculations)
                    Print("   Ajustement : ", DoubleToString(real_risk_pc, 3), "% -> ",
                          DoubleToString(verif_pc, 3), "% (lots ", DoubleToString(corrected, 2), ")");
                lots = corrected;
            }
        }
    }

    if(lots < min_lot) lots = min_lot;

    // Marge disponible
    double margin_required = 0.0;
    if(OrderCalcMargin(order_type, symbol, lots, entry, margin_required))
    {
        double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
        if(margin_required > free_margin && free_margin > 0)
        {
            double adjusted = lots * (free_margin / margin_required) * 0.95;
            adjusted = MathFloor(adjusted / lot_step) * lot_step;
            if(adjusted < min_lot) adjusted = min_lot;

            GDP_SetStatus(GDP_T("Marge insuffisante : volume réduit à ", "Not enough margin: lot size reduced to ") + DoubleToString(adjusted, 2), GDP_C_SELL);
            lots = adjusted;
        }
    }

    if(GDP_ShowCalculations)
        Print("   Resultat : ", DoubleToString(lots, 2), " lots | risque total ",
              DoubleToString(real_risk_pc, 2), "%");

    return lots;
}

//+------------------------------------------------------------------+
//| RECALCUL COMPLET                                                  |
//+------------------------------------------------------------------+
void GDP_UpdateCalculations()
{
    double entry = gdp_pending_mode ? gdp_pending_price : gdp_entry_price;

    if(entry > 0 && gdp_stop_loss > 0 && gdp_risk_percent > 0)
        gdp_lots = GDP_CalculatePositionSizeWithAllCosts(entry, gdp_stop_loss, gdp_risk_percent, _Symbol);
    else
        gdp_lots = 0.0;

    gdp_potential_profit = 0.0;
    gdp_potential_loss   = 0.0;
    gdp_total_costs      = 0.0;

    if(gdp_lots > 0 && entry > 0 && gdp_stop_loss > 0)
    {
        ENUM_ORDER_TYPE type = (entry > gdp_stop_loss) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

        if(gdp_take_profit > 0)
        {
            if(!OrderCalcProfit(type, _Symbol, gdp_lots, entry, gdp_take_profit, gdp_potential_profit))
                gdp_potential_profit = 0.0;
        }
        if(!OrderCalcProfit(type, _Symbol, gdp_lots, entry, gdp_stop_loss, gdp_potential_loss))
            gdp_potential_loss = 0.0;

        gdp_potential_loss = MathAbs(gdp_potential_loss);
        gdp_total_costs    = GDP_CalculateAllCosts(gdp_lots, _Symbol);
    }
}

//--- RR net : frais deduits du profit et ajoutes a la perte
double GDP_GetRRNet()
{
    if(gdp_lots <= 0 || gdp_potential_profit <= 0 || gdp_potential_loss <= 0) return 0.0;

    double profit_net = gdp_potential_profit - gdp_total_costs;
    double loss_net   = gdp_potential_loss + gdp_total_costs;
    if(loss_net <= 0) return 0.0;

    double rr = profit_net / loss_net;
    return (rr < 0) ? 0.0 : rr;
}

//--- RR net volatilite : ajoute le slippage estime des deux cotes
double GDP_GetRRNetVol()
{
    if(gdp_lots <= 0 || gdp_potential_profit <= 0 || gdp_potential_loss <= 0) return 0.0;

    double slip_pips  = GDP_GetVolSlippagePips();
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double pip        = GDP_PipSize(_Symbol);

    double slip_money = 0.0;
    if(tick_size > 0 && tick_value > 0)
        slip_money = ((slip_pips * pip) / tick_size) * tick_value * gdp_lots;

    double profit_net = gdp_potential_profit - gdp_total_costs - slip_money;
    double loss_net   = gdp_potential_loss + gdp_total_costs + slip_money;
    if(loss_net <= 0) return 0.0;

    double rr = profit_net / loss_net;
    return (rr < 0) ? 0.0 : rr;
}

//+------------------------------------------------------------------+
//| LIGNES DE PRIX (Entry / Pending / SL / TP)                        |
//+------------------------------------------------------------------+
void GDP_CreateOneLine(string name, double price, color clr, ENUM_LINE_STYLE style,
                       int width, bool draggable, string tooltip)
{
    if(price <= 0) return;

    if(ObjectFind(0, name) < 0)
        ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);

    ObjectSetDouble(0, name, OBJPROP_PRICE, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_STYLE, style);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, draggable);
    ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
    ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetString(0, name, OBJPROP_TEXT, tooltip);
    ObjectSetString(0, name, OBJPROP_TOOLTIP, tooltip);
}

void GDP_DeleteLines()
{
    ObjectDelete(0, GDP_LINE_ENTRY);
    ObjectDelete(0, GDP_LINE_PENDING);
    ObjectDelete(0, GDP_LINE_SL);
    ObjectDelete(0, GDP_LINE_TP);
    ChartRedraw();
}

void GDP_CreateLines()
{
    if(gdp_pending_mode)
    {
        ObjectDelete(0, GDP_LINE_ENTRY);
        GDP_CreateOneLine(GDP_LINE_PENDING, gdp_pending_price, GDP_C_WARN, STYLE_SOLID, 3, true,
                          "Prix de l'ordre en attente");
    }
    else
    {
        ObjectDelete(0, GDP_LINE_PENDING);
        // En mode marche, l'entree suit le prix courant : ligne informative, non deplacable
        GDP_CreateOneLine(GDP_LINE_ENTRY, gdp_entry_price, GDP_C_ACCENT, STYLE_DASH, 2, false,
                          "Entree au marche (prix courant)");
    }

    GDP_CreateOneLine(GDP_LINE_SL, gdp_stop_loss,   GDP_C_SELL,   STYLE_SOLID, 3, true, "Stop Loss");
    GDP_CreateOneLine(GDP_LINE_TP, gdp_take_profit, GDP_C_BUY, STYLE_SOLID, 3, true, "Take Profit");

    ChartRedraw();
}

//--- synchronise les lignes existantes avec les valeurs courantes
void GDP_RefreshLines()
{
    if(!gdp_lines_visible) return;
    GDP_CreateLines();
}

void GDP_ToggleLines()
{
    gdp_lines_visible = !gdp_lines_visible;

    if(gdp_lines_visible) GDP_CreateLines();
    else                  GDP_DeleteLines();

    GDP_SetStatus(gdp_lines_visible ? GDP_T("Lignes affichées (déplaçables à la souris).", "Lines shown (drag them on the chart).") : GDP_T("Lignes masquées.", "Lines hidden."),
                  GDP_C_NEUTRAL);
}

//--- une ligne a ete deplacee a la souris : on repercute sur les champs et le calcul
void GDP_HandleLineDrag(string line_name)
{
    if(line_name == GDP_LINE_PENDING && gdp_pending_mode)
    {
        gdp_pending_price = ObjectGetDouble(0, line_name, OBJPROP_PRICE);
        if(ObjectFind(0, GDP_PFX "EntryEdit") >= 0)
            ObjectSetString(0, GDP_PFX "EntryEdit", OBJPROP_TEXT, DoubleToString(gdp_pending_price, _Digits));
    }
    else if(line_name == GDP_LINE_SL)
    {
        gdp_stop_loss = ObjectGetDouble(0, line_name, OBJPROP_PRICE);
        if(ObjectFind(0, GDP_PFX "StopEdit") >= 0)
            ObjectSetString(0, GDP_PFX "StopEdit", OBJPROP_TEXT, DoubleToString(gdp_stop_loss, _Digits));
    }
    else if(line_name == GDP_LINE_TP)
    {
        gdp_take_profit = ObjectGetDouble(0, line_name, OBJPROP_PRICE);
        if(ObjectFind(0, GDP_PFX "TakeEdit") >= 0)
            ObjectSetString(0, GDP_PFX "TakeEdit", OBJPROP_TEXT, DoubleToString(gdp_take_profit, _Digits));
    }
    else
    {
        return;   // ligne inconnue ou entree marche (non deplacable)
    }

    GDP_UpdateCalculations();
    GDP_UpdatePanel();
}

//+------------------------------------------------------------------+
//| PANNEAU PRINCIPAL                                                 |
//+------------------------------------------------------------------+
//  Un seul parcours decrit la mise en page. Appele avec draw = false
//  il se contente de mesurer, avec draw = true il dessine : la hauteur
//  du panneau ne peut donc jamais se desynchroniser de son contenu.
int GDP_LayoutPanel(bool draw)
{
    int x  = gdp_panel_x;
    int w  = gdp_panel_width;
    int y  = gdp_panel_y;

    int left   = x + 16;
    int right  = x + w - 16;
    int inner  = w - 32;

    //=============== BARRE DE TITRE ===============
    if(draw)
    {
        GDP_CreateRectangle(GDP_PFX "TitleBar", x, y, x + w, y + 30, GDP_C_TITLE);

        GDP_CreateButton(GDP_PFX "DragHandle", x + 30, y + 3, w - 90, 24, "", GDP_C_TITLE);
        ObjectSetInteger(0, GDP_PFX "DragHandle", OBJPROP_BORDER_TYPE, BORDER_FLAT);
        ObjectSetInteger(0, GDP_PFX "DragHandle", OBJPROP_BORDER_COLOR, GDP_C_TITLE);

        GDP_CreateLabel(GDP_PFX "Title", left, y + 8,
                        GDP_T("GDP  ·  Gestionnaire de positions", "GDP  ·  Position Manager"),
                        GDP_C_TEXT, 10);

        GDP_Btn(GDP_PFX "MinimizeButton", x + w - 52, y + 6, 20, 18, "_", GDP_C_NEUTRAL);
        GDP_Btn(GDP_PFX "CloseWindowButton", x + w - 28, y + 6, 20, 18, "×", GDP_C_SELL);
    }
    y += 30;

    if(gdp_panel_minimized) return (y - gdp_panel_y);

    y += 10;

    //=============== MODE + LIGNES ===============
    //  Deux demi-boutons jointifs : le mode actif est colore, l'autre eteint.
    int seg_w = 108;
    if(draw)
    {
        GDP_Btn(GDP_PFX "ModeMarket", left, y, seg_w, 26,
                GDP_T("MARCHÉ", "MARKET"),
                gdp_pending_mode ? GDP_C_NEUTRAL : GDP_C_ACCENT, GDP_C_TEXT, 8);

        GDP_Btn(GDP_PFX "ModePending", left + seg_w + 2, y, seg_w, 26,
                GDP_T("EN ATTENTE", "PENDING"),
                gdp_pending_mode ? GDP_C_ACCENT : GDP_C_NEUTRAL, GDP_C_TEXT, 8);

        GDP_Btn(GDP_PFX "LinesButton", right - 120, y, 120, 26,
                gdp_lines_visible ? GDP_T("LIGNES : ON", "LINES: ON")
                                  : GDP_T("LIGNES : OFF", "LINES: OFF"),
                gdp_lines_visible ? GDP_C_WARN : GDP_C_NEUTRAL,
                gdp_lines_visible ? GDP_C_TITLE : GDP_C_TEXT, 8);
    }
    y += 36;

    //=============== PARAMETRES ===============
    double display_price = gdp_pending_mode ? gdp_pending_price : gdp_entry_price;
    double pip           = GDP_PipSize(_Symbol);
    double balance       = AccountInfoDouble(ACCOUNT_BALANCE);

    int lbl_w   = 112;              // colonne des libelles
    int field_x = left + lbl_w;
    int field_w = 104;
    int side_x  = field_x + field_w + 12;

    //--- prix d'entree
    if(draw)
    {
        GDP_CreateLabel(GDP_PFX "EntryLabel", left, y + 4,
                        gdp_pending_mode ? GDP_T("Prix de l'ordre", "Order price")
                                         : GDP_T("Prix d'entrée", "Entry price"),
                        GDP_C_TEXT_DIM, 9);

        GDP_Field(GDP_PFX "EntryEdit", field_x, y, field_w, 22,
                  DoubleToString(display_price, _Digits), !gdp_pending_mode);

        GDP_CreateLabel(GDP_PFX "EntryCurrent", side_x, y + 4,
                        GDP_T("marché ", "market ") +
                        DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits),
                        GDP_C_TEXT_DIM, 8);
    }
    y += 26;

    //--- stop loss
    if(draw)
    {
        GDP_CreateLabel(GDP_PFX "StopLabel", left, y + 4, "Stop Loss", GDP_C_TEXT_DIM, 9);
        GDP_Field(GDP_PFX "StopEdit", field_x, y, field_w, 22, DoubleToString(gdp_stop_loss, _Digits));

        double sp = (pip > 0 && gdp_stop_loss > 0) ? MathAbs(display_price - gdp_stop_loss) / pip : 0;
        GDP_CreateLabel(GDP_PFX "StopPips", side_x, y + 4,
                        DoubleToString(sp, 1) + " pips", GDP_C_SELL, 8);
    }
    y += 26;

    //--- take profit
    if(draw)
    {
        GDP_CreateLabel(GDP_PFX "TakeLabel", left, y + 4, "Take Profit", GDP_C_TEXT_DIM, 9);
        GDP_Field(GDP_PFX "TakeEdit", field_x, y, field_w, 22, DoubleToString(gdp_take_profit, _Digits));

        double tp = (pip > 0 && gdp_take_profit > 0) ? MathAbs(gdp_take_profit - display_price) / pip : 0;
        GDP_CreateLabel(GDP_PFX "TakePips", side_x, y + 4,
                        DoubleToString(tp, 1) + " pips", GDP_C_BUY, 8);
    }
    y += 26;

    //--- risque
    if(draw)
    {
        GDP_CreateLabel(GDP_PFX "RiskLabel", left, y + 4,
                        GDP_T("Risque par trade", "Risk per trade"), GDP_C_TEXT_DIM, 9);
        GDP_Field(GDP_PFX "RiskEdit", field_x, y, field_w, 22, DoubleToString(gdp_risk_percent, 2));
        GDP_CreateLabel(GDP_PFX "RiskPct", side_x, y + 4,
                        "% " + GDP_T("du solde", "of balance"), GDP_C_TEXT_DIM, 8);
    }
    y += 34;

    //=============== RESULTAT (la zone qui compte) ===============
    int box_h = 82;
    if(draw)
    {
        GDP_CreateRectangle(GDP_PFX "ResultBox", x + 10, y, x + w - 10, y + box_h, GDP_C_PANEL_ALT);

        int c1 = left + 2;
        int c2 = x + w / 2 + 6;

        GDP_CreateLabel(GDP_PFX "LotCaption", c1, y + 10,
                        GDP_T("VOLUME", "LOT SIZE"), GDP_C_TEXT_DIM, 8);
        GDP_CreateLabel(GDP_PFX "RiskCaption", c2, y + 10,
                        GDP_T("RISQUE RÉEL", "ACTUAL RISK"), GDP_C_TEXT_DIM, 8);

        GDP_CreateLabel(GDP_PFX "LotValue", c1, y + 26, DoubleToString(gdp_lots, 2), GDP_C_ACCENT, 16);
        GDP_CreateLabel(GDP_PFX "RiskValue", c2, y + 26, "$0.00", GDP_C_WARN, 16);

        GDP_CreateLabel(GDP_PFX "LotUnit", c1 + 62, y + 33, "lots", GDP_C_TEXT_DIM, 8);

        GDP_CreateRectangle(GDP_PFX "ResultSep", c1, y + 56, x + w - 18, y + 57, GDP_C_BORDER);

        GDP_CreateLabel(GDP_PFX "GainLine", c1, y + 63,
                        GDP_T("Gain potentiel", "Potential gain") + " $0.00", GDP_C_TEXT_DIM, 8);
        GDP_CreateLabel(GDP_PFX "RRValue", c2, y + 63, "1:0.00", GDP_C_TEXT_DIM, 9);
    }
    y += box_h + 12;

    //=============== ACTIONS ===============
    if(gdp_pending_mode)
    {
        if(draw)
        {
            GDP_Btn(GDP_PFX "PlaceButton", left, y, inner, 34,
                    GDP_T("PLACER L'ORDRE", "PLACE ORDER"), GDP_C_ACCENT, GDP_C_TEXT, 10);
        }
        y += 40;

        if(draw)
            GDP_CreateLabel(GDP_PFX "OrderTypeLabel", left, y,
                            GDP_T("Type d'ordre", "Order type"), GDP_C_TEXT_DIM, 8);
        y += 16;

        if(draw)
        {
            int bw = (inner - 9) / 4;
            GDP_Btn(GDP_PFX "BuyLimitButton", left, y, bw, 24, "BUY LIM",
                    gdp_pending_type == ORDER_TYPE_BUY_LIMIT ? GDP_C_BUY : GDP_C_NEUTRAL);
            GDP_Btn(GDP_PFX "BuyStopButton", left + (bw + 3), y, bw, 24, "BUY STP",
                    gdp_pending_type == ORDER_TYPE_BUY_STOP ? GDP_C_BUY : GDP_C_NEUTRAL);
            GDP_Btn(GDP_PFX "SellLimitButton", left + 2 * (bw + 3), y, bw, 24, "SELL LIM",
                    gdp_pending_type == ORDER_TYPE_SELL_LIMIT ? GDP_C_SELL : GDP_C_NEUTRAL);
            GDP_Btn(GDP_PFX "SellStopButton", left + 3 * (bw + 3), y, bw, 24, "SELL STP",
                    gdp_pending_type == ORDER_TYPE_SELL_STOP ? GDP_C_SELL : GDP_C_NEUTRAL);
        }
        y += 30;
    }
    else
    {
        if(draw)
        {
            int half = (inner - 8) / 2;
            GDP_Btn(GDP_PFX "BuyButton", left, y, half, 36,
                    GDP_T("ACHETER", "BUY"), GDP_C_BUY, GDP_C_TEXT, 11);
            GDP_Btn(GDP_PFX "SellButton", left + half + 8, y, half, 36,
                    GDP_T("VENDRE", "SELL"), GDP_C_SELL, GDP_C_TEXT, 11);
        }
        y += 42;
    }

    if(draw)
        GDP_Btn(GDP_PFX "CloseAllButton", left, y, inner, 24,
                GDP_T("Tout fermer sur ce symbole", "Close everything on this symbol"),
                GDP_C_NEUTRAL, GDP_C_TEXT, 8);
    y += 32;

    //=============== DETAIL AVANCE (replie par defaut) ===============
    if(draw)
        GDP_Btn(GDP_PFX "AdvToggle", left, y, inner, 22,
                (gdp_advanced ? "[-]  " : "[+]  ") + GDP_T("Détail avancé", "Advanced details"),
                GDP_C_PANEL_ALT, GDP_C_TEXT_DIM, 8);
    y += 26;

    if(gdp_advanced)
    {
        int row = 17;
        if(draw)
        {
            int vx = left + 170;

            GDP_CreateLabel(GDP_PFX "CommLabel", left, y, "Commission", GDP_C_TEXT_DIM, 8);
            GDP_CreateLabel(GDP_PFX "CommValue", vx, y, "$0.00", GDP_C_TEXT, 8);

            GDP_CreateLabel(GDP_PFX "RRNetLabel", left, y + row,
                            GDP_T("R/R après frais", "R/R after costs"), GDP_C_TEXT_DIM, 8);
            GDP_CreateLabel(GDP_PFX "RRNetValue", vx, y + row, "1:0.00", GDP_C_TEXT, 8);

            GDP_CreateLabel(GDP_PFX "NetLabel", left, y + 2 * row,
                            GDP_T("Gain net estimé", "Estimated net gain"), GDP_C_TEXT_DIM, 8);
            GDP_CreateLabel(GDP_PFX "NetValue", vx, y + 2 * row, "$0.00", GDP_C_TEXT, 8);

            GDP_CreateLabel(GDP_PFX "BalanceLabel", left, y + 3 * row,
                            GDP_T("Solde du compte", "Account balance"), GDP_C_TEXT_DIM, 8);
            GDP_CreateLabel(GDP_PFX "BalanceValue", vx, y + 3 * row,
                            "$" + DoubleToString(balance, 2), GDP_C_TEXT, 8);
        }
        y += 4 * row;

        if(GDP_ShowVolatility)
        {
            if(draw)
            {
                int vx = left + 170;
                GDP_CreateLabel(GDP_PFX "VolLabel", left, y,
                                GDP_T("Slippage volatilité", "Volatility slippage"), GDP_C_TEXT_DIM, 8);
                GDP_CreateLabel(GDP_PFX "VolValue", vx, y, "0.0 pips", GDP_C_TEXT, 8);

                GDP_CreateLabel(GDP_PFX "RRVolLabel", left, y + row,
                                GDP_T("R/R en marché volatil", "R/R in volatile market"), GDP_C_TEXT_DIM, 8);
                GDP_CreateLabel(GDP_PFX "RRVolValue", vx, y + row, "1:0.00", GDP_C_TEXT, 8);
            }
            y += 2 * row;
        }
        y += 6;
    }

    //=============== BARRE D'OUTILS ===============
    if(draw)
    {
        int bw = (inner - 9) / 4;

        GDP_Btn(GDP_PFX "ToolPositions", left, y, bw, 26, "Positions",
                gdp_pos_visible ? GDP_C_ACCENT : GDP_C_PANEL_ALT,
                gdp_pos_visible ? GDP_C_TEXT : GDP_C_TEXT_DIM);

        GDP_Btn(GDP_PFX "ToolJournal", left + (bw + 3), y, bw, 26, "Journal",
                gdp_jrn_visible ? GDP_C_ACCENT : GDP_C_PANEL_ALT,
                gdp_jrn_visible ? GDP_C_TEXT : GDP_C_TEXT_DIM);

        GDP_Btn(GDP_PFX "ToolReview", left + 2 * (bw + 3), y, bw, 26,
                GDP_T("Revue", "Review"),
                gdp_rev_visible ? GDP_C_ACCENT : GDP_C_PANEL_ALT,
                gdp_rev_visible ? GDP_C_TEXT : GDP_C_TEXT_DIM);

        GDP_Btn(GDP_PFX "ToolBilan", left + 3 * (bw + 3), y, bw, 26,
                GDP_T("Bilan", "Report"),
                gdp_bilan_visible ? GDP_C_ACCENT : GDP_C_PANEL_ALT,
                gdp_bilan_visible ? GDP_C_TEXT : GDP_C_TEXT_DIM);
    }
    y += 32;

    //=============== STATUT ===============
    if(draw)
        GDP_CreateLabel(GDP_PFX "Status", left, y, gdp_status_text, gdp_status_color, 8);
    y += 18;

    return (y - gdp_panel_y);
}

int GDP_PanelHeight()
{
    return GDP_LayoutPanel(false);
}

void GDP_CreatePanel()
{
    if(!gdp_panel_visible)
    {
        // Panneau ferme : une pastille pour le rouvrir
        GDP_Btn(GDP_PFX "ShowPanelButton", gdp_panel_x, gdp_panel_y, 120, 26, "GDP",
                GDP_C_ACCENT, GDP_C_TEXT, 9);
        ChartRedraw();
        return;
    }

    int h = GDP_LayoutPanel(false);

    GDP_CreateRectangle(GDP_PFX "Border", gdp_panel_x - 1, gdp_panel_y - 1,
                        gdp_panel_x + gdp_panel_width + 1, gdp_panel_y + h + 1, GDP_C_BORDER);
    GDP_CreateRectangle(GDP_PFX "Background", gdp_panel_x, gdp_panel_y,
                        gdp_panel_x + gdp_panel_width, gdp_panel_y + h, GDP_C_PANEL);

    GDP_LayoutPanel(true);
    GDP_UpdatePanel();
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| PANNEAU PRINCIPAL - rafraichissement des valeurs                  |
//+------------------------------------------------------------------+
void GDP_UpdatePanel()
{
    if(!gdp_panel_visible || gdp_panel_minimized) return;
    if(ObjectFind(0, GDP_PFX "LotValue") < 0) return;

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double entry   = gdp_pending_mode ? gdp_pending_price : gdp_entry_price;
    double pip     = GDP_PipSize(_Symbol);

    //--- volume
    ObjectSetString(0, GDP_PFX "LotValue", OBJPROP_TEXT, DoubleToString(gdp_lots, 2));

    //--- risque reel : la perte au SL, frais compris
    double risk_real = gdp_potential_loss + gdp_total_costs;
    if(risk_real <= 0) risk_real = balance * gdp_risk_percent / 100.0;   // avant tout calcul
    ObjectSetString(0, GDP_PFX "RiskValue", OBJPROP_TEXT, "$" + DoubleToString(risk_real, 2));

    //--- distances
    if(pip > 0)
    {
        double sp = (gdp_stop_loss   > 0) ? MathAbs(entry - gdp_stop_loss) / pip   : 0;
        double tp = (gdp_take_profit > 0) ? MathAbs(gdp_take_profit - entry) / pip : 0;
        if(ObjectFind(0, GDP_PFX "StopPips") >= 0)
            ObjectSetString(0, GDP_PFX "StopPips", OBJPROP_TEXT, DoubleToString(sp, 1) + " pips");
        if(ObjectFind(0, GDP_PFX "TakePips") >= 0)
            ObjectSetString(0, GDP_PFX "TakePips", OBJPROP_TEXT, DoubleToString(tp, 1) + " pips");
    }

    if(ObjectFind(0, GDP_PFX "EntryCurrent") >= 0)
        ObjectSetString(0, GDP_PFX "EntryCurrent", OBJPROP_TEXT,
                        GDP_T("marché ", "market ") +
                        DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits));

    //--- gain potentiel et rapport gain/risque
    double commission = (gdp_lots > 0) ? gdp_lots * GDP_GetCommissionPerLot(_Symbol) : 0.0;
    double net        = gdp_potential_profit - commission;

    ObjectSetString(0, GDP_PFX "GainLine", OBJPROP_TEXT,
                    GDP_T("Gain potentiel ", "Potential gain ") + "$" +
                    DoubleToString(gdp_potential_profit, 2));

    double rr = GDP_CalculateRiskReward(entry, gdp_stop_loss, gdp_take_profit);
    ObjectSetString(0, GDP_PFX "RRValue", OBJPROP_TEXT, rr > 0 ? "1:" + DoubleToString(rr, 2) : "1:0.00");
    ObjectSetInteger(0, GDP_PFX "RRValue", OBJPROP_COLOR,
                     rr >= 2.0 ? GDP_C_BUY : (rr >= 1.0 ? GDP_C_WARN : GDP_C_SELL));

    //--- bloc avance
    if(gdp_advanced && ObjectFind(0, GDP_PFX "CommValue") >= 0)
    {
        ObjectSetString(0, GDP_PFX "CommValue", OBJPROP_TEXT, "$" + DoubleToString(commission, 2));

        ObjectSetString(0, GDP_PFX "NetValue", OBJPROP_TEXT, "$" + DoubleToString(net, 2));
        ObjectSetInteger(0, GDP_PFX "NetValue", OBJPROP_COLOR,
                         net > 0 ? GDP_C_BUY : (net < 0 ? GDP_C_SELL : GDP_C_TEXT_DIM));

        double rr_net = GDP_GetRRNet();
        ObjectSetString(0, GDP_PFX "RRNetValue", OBJPROP_TEXT,
                        rr_net > 0 ? "1:" + DoubleToString(rr_net, 2) : "1:0.00");
        ObjectSetInteger(0, GDP_PFX "RRNetValue", OBJPROP_COLOR,
                         rr_net >= 2.0 ? GDP_C_BUY : (rr_net >= 1.0 ? GDP_C_WARN : GDP_C_SELL));

        ObjectSetString(0, GDP_PFX "BalanceValue", OBJPROP_TEXT, "$" + DoubleToString(balance, 2));

        if(GDP_ShowVolatility && ObjectFind(0, GDP_PFX "VolValue") >= 0)
        {
            double slip = GDP_GetVolSlippagePips();
            ObjectSetString(0, GDP_PFX "VolValue", OBJPROP_TEXT, DoubleToString(slip, 1) + " pips");
            ObjectSetInteger(0, GDP_PFX "VolValue", OBJPROP_COLOR,
                             slip < 1.0 ? GDP_C_BUY : (slip < 5.0 ? GDP_C_WARN : GDP_C_SELL));

            double rr_vol = GDP_GetRRNetVol();
            ObjectSetString(0, GDP_PFX "RRVolValue", OBJPROP_TEXT,
                            rr_vol > 0 ? "1:" + DoubleToString(rr_vol, 2) : "1:0.00");
            ObjectSetInteger(0, GDP_PFX "RRVolValue", OBJPROP_COLOR,
                             rr_vol >= 2.0 ? GDP_C_BUY : (rr_vol >= 1.0 ? GDP_C_WARN : GDP_C_SELL));
        }
    }

    ChartRedraw();
}

//+------------------------------------------------------------------+
//| PANNEAU PRINCIPAL - ouverture / fermeture / mode                  |
//+------------------------------------------------------------------+
void GDP_RebuildPanel()
{
    GDP_DeletePanelObjects();
    GDP_CreatePanel();
}

void GDP_ClosePanel()
{
    gdp_panel_visible = false;
    GDP_DeletePanelObjects();
    GDP_CreatePanel();
}

void GDP_ShowPanelFunc()
{
    gdp_panel_visible = true;
    GDP_RebuildPanel();
}

void GDP_ToggleMinimize()
{
    gdp_panel_minimized = !gdp_panel_minimized;
    GDP_RebuildPanel();
}

//--- lit les champs de saisie sans attendre la validation par Entree
void GDP_ReadEditFields()
{
    if(ObjectFind(0, GDP_PFX "StopEdit") >= 0)
    {
        double v = StringToDouble(ObjectGetString(0, GDP_PFX "StopEdit", OBJPROP_TEXT));
        if(v > 0) gdp_stop_loss = v;
    }
    if(ObjectFind(0, GDP_PFX "TakeEdit") >= 0)
    {
        double v = StringToDouble(ObjectGetString(0, GDP_PFX "TakeEdit", OBJPROP_TEXT));
        if(v > 0) gdp_take_profit = v;
    }
    if(ObjectFind(0, GDP_PFX "RiskEdit") >= 0)
    {
        double v = StringToDouble(ObjectGetString(0, GDP_PFX "RiskEdit", OBJPROP_TEXT));
        if(v > 0) gdp_risk_percent = v;
    }
    if(gdp_pending_mode && ObjectFind(0, GDP_PFX "EntryEdit") >= 0)
    {
        double v = StringToDouble(ObjectGetString(0, GDP_PFX "EntryEdit", OBJPROP_TEXT));
        if(v > 0) gdp_pending_price = v;
    }
}

void GDP_TogglePendingMode()
{
    GDP_ReadEditFields();

    gdp_pending_mode = !gdp_pending_mode;

    if(gdp_pending_mode)
    {
        if(gdp_pending_price <= 0)
            gdp_pending_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        if(gdp_pending_type != ORDER_TYPE_BUY_LIMIT && gdp_pending_type != ORDER_TYPE_BUY_STOP &&
           gdp_pending_type != ORDER_TYPE_SELL_LIMIT && gdp_pending_type != ORDER_TYPE_SELL_STOP)
            gdp_pending_type = ORDER_TYPE_BUY_LIMIT;
    }
    else
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        gdp_entry_price = (bid + ask) / 2.0;
    }

    GDP_RefreshLines();
    GDP_UpdateCalculations();
    GDP_RebuildPanel();

    GDP_SetStatus(gdp_pending_mode ? GDP_T("Ordre en attente : choisissez le prix d'entrée.", "Pending order: pick your entry price.") : GDP_T("Marché : entrée au prix courant.", "Market: entry at current price."),
                  GDP_C_NEUTRAL);
}

//+------------------------------------------------------------------+
//| PLACEMENT D'ORDRES                                                |
//+------------------------------------------------------------------+
bool GDP_PreTradeChecks()
{
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    {
        GDP_SetStatus(GDP_T("Trading désactivé : activez le bouton Algo Trading du terminal.", "Trading disabled: turn on the terminal Algo Trading button."), GDP_C_SELL);
        return false;
    }
    if(gdp_lots <= 0)
    {
        GDP_SetStatus(GDP_T("Volume invalide : vérifiez l'entrée, le Stop Loss et le risque.", "Invalid lot size: check entry, stop loss and risk."), GDP_C_SELL);
        return false;
    }
    if(gdp_stop_loss <= 0)
    {
        GDP_SetStatus(GDP_T("Stop Loss non défini.", "Stop Loss not set."), GDP_C_SELL);
        return false;
    }
    return true;
}

void GDP_OpenMarketPosition(ENUM_ORDER_TYPE order_type)
{
    GDP_ReadEditFields();
    GDP_UpdateCalculations();

    if(!GDP_PreTradeChecks()) return;

    double lots  = GDP_NormalizeLots(gdp_lots, _Symbol);
    double price = (order_type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // Coherence SL / sens de l'ordre
    if(order_type == ORDER_TYPE_BUY && gdp_stop_loss >= price)
    {
        GDP_SetStatus(GDP_T("Achat impossible : le Stop Loss doit être sous le prix courant.", "Cannot buy: stop loss must sit below current price."), GDP_C_SELL);
        return;
    }
    if(order_type == ORDER_TYPE_SELL && gdp_stop_loss <= price)
    {
        GDP_SetStatus(GDP_T("Vente impossible : le Stop Loss doit être au-dessus du prix courant.", "Cannot sell: stop loss must sit above current price."), GDP_C_SELL);
        return;
    }

    gdp_trade.SetExpertMagicNumber(GDP_MagicNumber);
    gdp_trade.SetDeviationInPoints(GDP_Deviation);

    if(gdp_trade.PositionOpen(_Symbol, order_type, lots, price, gdp_stop_loss, gdp_take_profit, "GDP Market"))
    {
        ulong ticket = gdp_trade.ResultOrder();
        GDP_SetStatus(StringFormat("%s ouvert #%I64u | %.2f lots @ %s",
                                   order_type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                                   ticket, lots, DoubleToString(price, _Digits)), GDP_C_BUY);

        GDP_RecordEntry(order_type == ORDER_TYPE_BUY ? "BUY" : "SELL", "MARKET",
                        price, gdp_stop_loss, gdp_take_profit, lots, ticket);

        if(gdp_pos_visible) GDP_CreatePositionsPanel();
    }
    else
    {
        GDP_SetStatus(StringFormat(GDP_T("Ouverture refusée : %d - %s", "Order rejected: %d - %s"),
                                   gdp_trade.ResultRetcode(),
                                   gdp_trade.ResultRetcodeDescription()), GDP_C_SELL);
    }
}

void GDP_PlacePendingOrder()
{
    GDP_ReadEditFields();
    GDP_UpdateCalculations();

    if(!GDP_PreTradeChecks()) return;

    if(gdp_pending_price <= 0)
    {
        GDP_SetStatus(GDP_T("Prix de l'ordre non défini.", "Order price not set."), GDP_C_SELL);
        return;
    }

    double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spread = ask - bid;
    int    digits = _Digits;

    //--- le prix doit etre du bon cote du marche pour le type choisi
    bool   valid = false;
    string why   = "";

    if(gdp_pending_type == ORDER_TYPE_BUY_LIMIT)
    {
        valid = (gdp_pending_price < ask - spread);
        why   = "Buy Limit doit etre < " + DoubleToString(ask - spread, digits);
    }
    else if(gdp_pending_type == ORDER_TYPE_BUY_STOP)
    {
        valid = (gdp_pending_price > ask + spread);
        why   = "Buy Stop doit etre > " + DoubleToString(ask + spread, digits);
    }
    else if(gdp_pending_type == ORDER_TYPE_SELL_LIMIT)
    {
        valid = (gdp_pending_price > bid + spread);
        why   = "Sell Limit doit etre > " + DoubleToString(bid + spread, digits);
    }
    else if(gdp_pending_type == ORDER_TYPE_SELL_STOP)
    {
        valid = (gdp_pending_price < bid - spread);
        why   = "Sell Stop doit etre < " + DoubleToString(bid - spread, digits);
    }

    if(!valid)
    {
        GDP_SetStatus(GDP_T("Prix invalide : ", "Invalid price: ") + why, GDP_C_SELL);
        return;
    }

    //--- coherence SL / sens
    bool is_buy = (gdp_pending_type == ORDER_TYPE_BUY_LIMIT || gdp_pending_type == ORDER_TYPE_BUY_STOP);
    if(is_buy && gdp_stop_loss >= gdp_pending_price)
    {
        GDP_SetStatus(GDP_T("Ordre d'achat : le Stop Loss doit être sous le prix d'entrée.", "Buy order: stop loss must sit below entry price."), GDP_C_SELL);
        return;
    }
    if(!is_buy && gdp_stop_loss <= gdp_pending_price)
    {
        GDP_SetStatus(GDP_T("Ordre de vente : le Stop Loss doit être au-dessus du prix d'entrée.", "Sell order: stop loss must sit above entry price."), GDP_C_SELL);
        return;
    }

    double lots = GDP_NormalizeLots(gdp_lots, _Symbol);

    gdp_trade.SetExpertMagicNumber(GDP_MagicNumber);
    gdp_trade.SetDeviationInPoints(GDP_Deviation);

    bool   ok   = false;
    string name = "";

    if(gdp_pending_type == ORDER_TYPE_BUY_LIMIT)
    {
        name = "BUY LIMIT";
        ok = gdp_trade.BuyLimit(lots, gdp_pending_price, _Symbol, gdp_stop_loss, gdp_take_profit,
                                ORDER_TIME_GTC, 0, "GDP Pending");
    }
    else if(gdp_pending_type == ORDER_TYPE_BUY_STOP)
    {
        name = "BUY STOP";
        ok = gdp_trade.BuyStop(lots, gdp_pending_price, _Symbol, gdp_stop_loss, gdp_take_profit,
                               ORDER_TIME_GTC, 0, "GDP Pending");
    }
    else if(gdp_pending_type == ORDER_TYPE_SELL_LIMIT)
    {
        name = "SELL LIMIT";
        ok = gdp_trade.SellLimit(lots, gdp_pending_price, _Symbol, gdp_stop_loss, gdp_take_profit,
                                 ORDER_TIME_GTC, 0, "GDP Pending");
    }
    else if(gdp_pending_type == ORDER_TYPE_SELL_STOP)
    {
        name = "SELL STOP";
        ok = gdp_trade.SellStop(lots, gdp_pending_price, _Symbol, gdp_stop_loss, gdp_take_profit,
                                ORDER_TIME_GTC, 0, "GDP Pending");
    }

    if(ok)
    {
        ulong ticket = gdp_trade.ResultOrder();
        GDP_SetStatus(StringFormat("%s place #%I64u | %.2f lots @ %s",
                                   name, ticket, lots,
                                   DoubleToString(gdp_pending_price, digits)), GDP_C_BUY);

        GDP_RecordEntry(is_buy ? "BUY" : "SELL", name,
                        gdp_pending_price, gdp_stop_loss, gdp_take_profit, lots, ticket);
    }
    else
    {
        GDP_SetStatus(StringFormat(GDP_T("Placement refusé : %d - %s", "Order placement rejected: %d - %s"),
                                   gdp_trade.ResultRetcode(),
                                   gdp_trade.ResultRetcodeDescription()), GDP_C_SELL);
    }
}

//--- true si la position / l'ordre selectionne entre dans le perimetre du GDP
bool GDP_OwnsPosition(long magic)
{
    return (!GDP_ManageOnlyOwn || magic == GDP_MagicNumber);
}

void GDP_CloseAll()
{
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    {
        GDP_SetStatus(GDP_T("Trading désactivé : activez le bouton Algo Trading du terminal.", "Trading disabled: turn on the terminal Algo Trading button."), GDP_C_SELL);
        return;
    }

    int closed_positions = 0;
    int deleted_orders   = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(!GDP_OwnsPosition(PositionGetInteger(POSITION_MAGIC))) continue;

        if(gdp_trade.PositionClose(ticket)) closed_positions++;
    }

    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket == 0) continue;

        if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if(!GDP_OwnsPosition(OrderGetInteger(ORDER_MAGIC))) continue;

        if(gdp_trade.OrderDelete(ticket)) deleted_orders++;
    }

    GDP_SetStatus(StringFormat(GDP_T("Fermé : %d position(s), %d ordre(s) en attente.", "Closed: %d position(s), %d pending order(s)."),
                               closed_positions, deleted_orders), GDP_C_ACCENT);

    if(gdp_pos_visible) GDP_CreatePositionsPanel();
}

//+------------------------------------------------------------------+
//| GESTION DES POSITIONS OUVERTES                                    |
//+------------------------------------------------------------------+
//--- une position est a BE+ quand son SL couvre deja le prix d'entree
bool GDP_IsPositionAtBEPlus(ulong ticket)
{
    if(!PositionSelectByTicket(ticket)) return false;

    double sl   = PositionGetDouble(POSITION_SL);
    double open = PositionGetDouble(POSITION_PRICE_OPEN);
    if(sl <= 0) return false;

    return (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (sl >= open) : (sl <= open);
}

//--- place le SL au point mort reel : entree + commission + swap + spread
void GDP_SetBreakeven(ulong ticket)
{
    if(!PositionSelectByTicket(ticket))
    {
        GDP_SetStatus("Position #" + IntegerToString((long)ticket) + GDP_T(" introuvable.", " not found."), GDP_C_SELL);
        return;
    }

    double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    double current_sl = PositionGetDouble(POSITION_SL);
    double current_tp = PositionGetDouble(POSITION_TP);
    double lots       = PositionGetDouble(POSITION_VOLUME);
    double swap       = PositionGetDouble(POSITION_SWAP);
    string symbol     = PositionGetString(POSITION_SYMBOL);
    ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    //--- commission reellement payee, lue dans l'historique des deals
    double commission = 0.0;
    if(HistorySelectByPosition(PositionGetInteger(POSITION_IDENTIFIER)))
    {
        for(int d = 0; d < HistoryDealsTotal(); d++)
        {
            ulong deal = HistoryDealGetTicket(d);
            if(deal > 0) commission += MathAbs(HistoryDealGetDouble(deal, DEAL_COMMISSION));
        }
    }

    double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
    int    digits     = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

    if(tick_size <= 0 || tick_value <= 0 || lots <= 0 || point <= 0)
    {
        GDP_SetStatus(GDP_T("Seuil de rentabilité impossible : données du symbole indisponibles.", "Break-even failed: symbol data unavailable."), GDP_C_SELL);
        return;
    }

    //--- cout total a couvrir (le swap ne compte que s'il est negatif) + spread courant
    double total_cost = commission;
    if(swap < 0) total_cost += MathAbs(swap);

    double spread = SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID);
    total_cost += (spread / tick_size) * tick_value * lots;

    double cost_in_price = (total_cost / lots / tick_value) * tick_size;
    cost_in_price = MathCeil(cost_in_price / point) * point;
    cost_in_price = NormalizeDouble(cost_in_price, digits);

    double new_sl;
    bool   reachable;

    if(pos_type == POSITION_TYPE_BUY)
    {
        new_sl    = NormalizeDouble(open_price + cost_in_price, digits);
        reachable = (SymbolInfoDouble(symbol, SYMBOL_BID) > new_sl && (current_sl == 0 || current_sl < new_sl));
    }
    else
    {
        new_sl    = NormalizeDouble(open_price - cost_in_price, digits);
        reachable = (SymbolInfoDouble(symbol, SYMBOL_ASK) < new_sl && (current_sl == 0 || current_sl > new_sl));
    }

    if(!reachable)
    {
        GDP_SetStatus(StringFormat(GDP_T("Seuil #%I64u hors d'atteinte : le prix n'est pas assez avancé (seuil à %s).", "Break-even #%I64u out of reach: price has not moved far enough (level %s)."),
                                   ticket, DoubleToString(new_sl, digits)), GDP_C_SELL);
        return;
    }

    if(gdp_trade.PositionModify(ticket, new_sl, current_tp))
    {
        double pips = MathAbs(new_sl - open_price) / GDP_PipSize(symbol);
        GDP_SetStatus(StringFormat(GDP_T("Seuil posé #%I64u | SL %s (%.1f pips au-delà de l'entrée).", "Break-even set #%I64u | SL %s (%.1f pips past entry)."),
                                   ticket, DoubleToString(new_sl, digits), pips), GDP_C_BUY);
    }
    else
    {
        GDP_SetStatus(StringFormat(GDP_T("Seuil refusé : %d - %s", "Break-even rejected: %d - %s"),
                                   gdp_trade.ResultRetcode(),
                                   gdp_trade.ResultRetcodeDescription()), GDP_C_SELL);
    }

    if(gdp_pos_visible) GDP_CreatePositionsPanel();
}

void GDP_ClosePositionByTicket(ulong ticket)
{
    if(gdp_trade.PositionClose(ticket))
        GDP_SetStatus("Position #" + IntegerToString((long)ticket) + GDP_T(" fermée.", " closed."), GDP_C_ACCENT);
    else
        GDP_SetStatus(StringFormat(GDP_T("Fermeture refusée : %d - %s", "Close rejected: %d - %s"),
                                   gdp_trade.ResultRetcode(),
                                   gdp_trade.ResultRetcodeDescription()), GDP_C_SELL);

    if(gdp_pos_visible) GDP_CreatePositionsPanel();
}

void GDP_DeletePositionsPanel()
{
    for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
    {
        string name = ObjectName(0, i);
        if(StringFind(name, GDP_POS_PFX) == 0)
            ObjectDelete(0, name);
    }
    ArrayResize(gdp_pos_tickets, 0);
    ChartRedraw();
}

void GDP_CreatePositionsPanel()
{
    GDP_DeletePositionsPanel();

    int y = gdp_pos_y;

    GDP_CreateRectangle(GDP_POS_PFX "Border", gdp_pos_x - 2, gdp_pos_y - 2,
                        gdp_pos_x + gdp_pos_width + 2, gdp_pos_y + gdp_pos_height + 2, GDP_C_BORDER);
    GDP_CreateRectangle(GDP_POS_PFX "Background", gdp_pos_x, gdp_pos_y,
                        gdp_pos_x + gdp_pos_width, gdp_pos_y + gdp_pos_height, GDP_C_PANEL);
    GDP_CreateRectangle(GDP_POS_PFX "TitleBar", gdp_pos_x, gdp_pos_y,
                        gdp_pos_x + gdp_pos_width, gdp_pos_y + 28, GDP_C_TITLE);

    GDP_CreateButton(GDP_POS_PFX "DragHandle", gdp_pos_x + 30, gdp_pos_y + 3,
                     gdp_pos_width - 60, 22, "", GDP_C_TITLE);
    ObjectSetInteger(0, GDP_POS_PFX "DragHandle", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, GDP_POS_PFX "DragHandle", OBJPROP_BORDER_COLOR, GDP_C_TITLE);

    GDP_CreateLabel(GDP_POS_PFX "Title", gdp_pos_x + 14, y + 7,
                    GDP_T("POSITIONS OUVERTES", "OPEN POSITIONS"), GDP_C_TEXT, 10);
    GDP_Btn(GDP_POS_PFX "CloseButton", gdp_pos_x + gdp_pos_width - 28, y + 5, 20, 18, "×", GDP_C_SELL);

    y += 34;

    GDP_CreateLabel(GDP_POS_PFX "HeaderSymbol",  gdp_pos_x + 14,  y,
                    GDP_T("Symbole", "Symbol"), GDP_C_TEXT_DIM, 8);
    GDP_CreateLabel(GDP_POS_PFX "HeaderType",    gdp_pos_x + 84,  y, "Type", GDP_C_TEXT_DIM, 8);
    GDP_CreateLabel(GDP_POS_PFX "HeaderLots",    gdp_pos_x + 134, y,
                    GDP_T("Volume", "Lots"), GDP_C_TEXT_DIM, 8);
    GDP_CreateLabel(GDP_POS_PFX "HeaderProfit",  gdp_pos_x + 184, y,
                    GDP_T("Gain/Perte", "P&L"), GDP_C_TEXT_DIM, 8);
    GDP_CreateLabel(GDP_POS_PFX "HeaderActions", gdp_pos_x + 254, y,
                    GDP_T("Actions", "Actions"), GDP_C_TEXT_DIM, 8);

    y += 20;

    int count = 0;

    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;

        string symbol = PositionGetString(POSITION_SYMBOL);
        if(symbol != _Symbol) continue;
        if(!GDP_OwnsPosition(PositionGetInteger(POSITION_MAGIC))) continue;

        string type   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        double lots   = PositionGetDouble(POSITION_VOLUME);
        double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        string tk     = IntegerToString((long)ticket);

        GDP_CreateLabel(GDP_POS_PFX "Symbol_" + tk, gdp_pos_x + 14,  y, symbol, GDP_C_TEXT, 8);
        GDP_CreateLabel(GDP_POS_PFX "Type_"   + tk, gdp_pos_x + 84,  y, type,
                        (type == "BUY") ? GDP_C_BUY : GDP_C_SELL, 8);
        GDP_CreateLabel(GDP_POS_PFX "Lots_"   + tk, gdp_pos_x + 134, y, DoubleToString(lots, 2), GDP_C_TEXT, 8);
        GDP_CreateLabel(GDP_POS_PFX "Profit_" + tk, gdp_pos_x + 184, y,
                        "$" + DoubleToString(profit, 2), profit >= 0 ? GDP_C_BUY : GDP_C_SELL, 8);

        bool at_be = GDP_IsPositionAtBEPlus(ticket);
        GDP_Btn(GDP_POS_PFX "BE_" + tk, gdp_pos_x + 254, y - 3, 38, 18,
                at_be ? "BE ok" : "BE+",
                at_be ? GDP_C_NEUTRAL : GDP_C_WARN,
                at_be ? GDP_C_TEXT_DIM : GDP_C_TITLE);

        GDP_Btn(GDP_POS_PFX "Close_" + tk, gdp_pos_x + 296, y - 3, 44, 18,
                GDP_T("Fermer", "Close"), GDP_C_SELL);

        int n = ArraySize(gdp_pos_tickets);
        ArrayResize(gdp_pos_tickets, n + 1);
        gdp_pos_tickets[n] = ticket;

        count++;
        y += 20;
    }

    if(count == 0)
        GDP_CreateLabel(GDP_POS_PFX "NoPositions", gdp_pos_x + 14, y,
                        GDP_T("Aucune position ouverte", "No open position"), GDP_C_TEXT_DIM, 9);

    ChartRedraw();
}

//--- rafraichit le P&L sans reconstruire le panneau, sauf si la liste a change
void GDP_RefreshPositionsPanel()
{
    if(!gdp_pos_visible) return;

    //--- la liste des tickets a-t-elle change ?
    ulong live[];
    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(!GDP_OwnsPosition(PositionGetInteger(POSITION_MAGIC))) continue;

        int n = ArraySize(live);
        ArrayResize(live, n + 1);
        live[n] = ticket;
    }

    bool same = (ArraySize(live) == ArraySize(gdp_pos_tickets));
    if(same)
    {
        for(int i = 0; i < ArraySize(live); i++)
            if(live[i] != gdp_pos_tickets[i]) { same = false; break; }
    }

    if(!same)
    {
        GDP_CreatePositionsPanel();
        return;
    }

    //--- meme liste : on ne met a jour que le P&L et l'etat BE
    for(int i = 0; i < ArraySize(live); i++)
    {
        if(!PositionSelectByTicket(live[i])) continue;

        string tk     = IntegerToString((long)live[i]);
        double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

        if(ObjectFind(0, GDP_POS_PFX "Profit_" + tk) >= 0)
        {
            ObjectSetString(0, GDP_POS_PFX "Profit_" + tk, OBJPROP_TEXT, "$" + DoubleToString(profit, 2));
            ObjectSetInteger(0, GDP_POS_PFX "Profit_" + tk, OBJPROP_COLOR, profit >= 0 ? GDP_C_BUY : GDP_C_SELL);
        }

        if(ObjectFind(0, GDP_POS_PFX "BE_" + tk) >= 0)
        {
            bool at_be = GDP_IsPositionAtBEPlus(live[i]);
            ObjectSetString(0, GDP_POS_PFX "BE_" + tk, OBJPROP_TEXT, at_be ? "BE ok" : "BE+");
            ObjectSetInteger(0, GDP_POS_PFX "BE_" + tk, OBJPROP_BGCOLOR, at_be ? GDP_C_NEUTRAL : GDP_C_WARN);
            ObjectSetInteger(0, GDP_POS_PFX "BE_" + tk, OBJPROP_COLOR, at_be ? GDP_C_TEXT_DIM : GDP_C_TITLE);
        }
    }

    ChartRedraw();
}

//+------------------------------------------------------------------+
//| BILAN - bornes de periode                                         |
//+------------------------------------------------------------------+
//  Toutes les bornes sont en heure serveur : c'est celle des deals.
datetime GDP_BilanDayStart()
{
    int reset_hour = GDP_DayResetHour;
    if(reset_hour < 0 || reset_hour > 23) reset_hour = 0;

    datetime now = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(now, dt);

    dt.hour = reset_hour;
    dt.min  = 0;
    dt.sec  = 0;
    datetime reset_today = StructToTime(dt);

    // Avant l'heure de reset, la journee en cours a commence hier
    if(now < reset_today) reset_today -= 86400;

    return reset_today;
}

datetime GDP_BilanWeekStart()
{
    datetime now = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(now, dt);

    // day_of_week : 0 = dimanche
    int days_since_monday = (dt.day_of_week == 0) ? 6 : (dt.day_of_week - 1);

    dt.hour = 0; dt.min = 0; dt.sec = 0;
    return StructToTime(dt) - days_since_monday * 86400;
}

datetime GDP_BilanMonthStart()
{
    datetime now = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(now, dt);

    dt.day  = 1;
    dt.hour = 0; dt.min = 0; dt.sec = 0;
    return StructToTime(dt);
}

datetime GDP_BilanPeriodStart(ENUM_GDP_PERIOD period)
{
    if(period == GDP_PERIOD_WEEK)  return GDP_BilanWeekStart();
    if(period == GDP_PERIOD_MONTH) return GDP_BilanMonthStart();
    return GDP_BilanDayStart();
}

string GDP_BilanPeriodLabel(ENUM_GDP_PERIOD period)
{
    if(period == GDP_PERIOD_WEEK)  return GDP_T("SEMAINE", "WEEK");
    if(period == GDP_PERIOD_MONTH) return GDP_T("MOIS", "MONTH");
    return GDP_T("JOUR", "DAY");
}

//+------------------------------------------------------------------+
//| BILAN - calcul depuis l'historique des deals                      |
//+------------------------------------------------------------------+
//  Ne compte que les deals de SORTIE : un trade = une cloture.
//  P&L net = profit + commission + swap.
bool GDP_ComputeStats(ENUM_GDP_PERIOD period, GDP_SymStats &stats[],
                      int &total_wins, int &total_losses, int &total_be, double &total_pnl)
{
    ArrayResize(stats, 0);
    total_wins   = 0;
    total_losses = 0;
    total_be     = 0;
    total_pnl    = 0.0;

    datetime from = GDP_BilanPeriodStart(period);
    datetime to   = TimeCurrent() + 60;   // marge : deals horodates a la seconde courante

    if(!HistorySelect(from, to))
    {
        Print("[GDP] Bilan : HistorySelect a echoue.");
        return false;
    }

    for(int i = 0; i < HistoryDealsTotal(); i++)
    {
        ulong deal = HistoryDealGetTicket(i);
        if(deal == 0) continue;

        long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
        if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

        long dtype = HistoryDealGetInteger(deal, DEAL_TYPE);
        if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) continue;   // exclut depots/retraits

        if(GDP_ManageOnlyOwn && HistoryDealGetInteger(deal, DEAL_MAGIC) != GDP_MagicNumber) continue;

        string symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
        if(symbol == "") continue;

        double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
                   + HistoryDealGetDouble(deal, DEAL_COMMISSION)
                   + HistoryDealGetDouble(deal, DEAL_SWAP);

        //--- retrouver ou creer la ligne de l'instrument
        int idx = -1;
        for(int k = 0; k < ArraySize(stats); k++)
            if(stats[k].symbol == symbol) { idx = k; break; }

        if(idx < 0)
        {
            idx = ArraySize(stats);
            ArrayResize(stats, idx + 1);
            stats[idx].symbol     = symbol;
            stats[idx].wins       = 0;
            stats[idx].losses     = 0;
            stats[idx].breakevens = 0;
            stats[idx].net_pnl    = 0.0;
        }

        stats[idx].net_pnl += pnl;
        total_pnl          += pnl;

        if(pnl > 0.001)       { stats[idx].wins++;       total_wins++;   }
        else if(pnl < -0.001) { stats[idx].losses++;     total_losses++; }
        else                  { stats[idx].breakevens++; total_be++;     }
    }

    //--- tri par |P&L| decroissant : ce qui pese le plus en premier
    int n = ArraySize(stats);
    for(int i = 0; i < n - 1; i++)
        for(int j = 0; j < n - 1 - i; j++)
            if(MathAbs(stats[j].net_pnl) < MathAbs(stats[j + 1].net_pnl))
            {
                GDP_SymStats tmp = stats[j];
                stats[j]     = stats[j + 1];
                stats[j + 1] = tmp;
            }

    return true;
}

//--- colonnes alignees : on complete a droite jusqu'a la largeur voulue
string GDP_PadRight(string s, int width)
{
    while(StringLen(s) < width) s += " ";
    return s;
}

//+------------------------------------------------------------------+
//| BILAN - panneau                                                   |
//+------------------------------------------------------------------+
void GDP_CloseBilan()
{
    ObjectsDeleteAll(0, GDP_BIL_PFX);
    gdp_bilan_visible = false;
    ChartRedraw();
}

void GDP_ShowBilan(ENUM_GDP_PERIOD period)
{
    ObjectsDeleteAll(0, GDP_BIL_PFX);

    gdp_bilan_visible = true;
    gdp_bilan_period  = period;
    gdp_bilan_refresh_countdown = 5;

    GDP_SymStats stats[];
    int total_wins, total_losses, total_be;
    double total_pnl;
    bool ok = GDP_ComputeStats(period, stats, total_wins, total_losses, total_be, total_pnl);

    int    n            = ArraySize(stats);
    int    total_trades = total_wins + total_losses + total_be;
    double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
    double start_balance = balance - total_pnl;      // solde avant les trades de la periode
    double pnl_pct      = (start_balance > 0) ? (total_pnl / start_balance) * 100.0 : 0.0;

    int x = gdp_bilan_x;
    int y = gdp_bilan_y;
    int w = gdp_bilan_width;

    //--- hauteur adaptee au nombre d'instruments, plafonnee a la hauteur du chart
    int rows = (total_trades == 0) ? 1 : n;
    int h    = 150 + rows * 16 + 34;
    int chart_h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
    if(y + h > chart_h - 10) h = chart_h - 10 - y;
    if(h < 190) h = 190;

    GDP_CreateRectangle(GDP_BIL_PFX "Border", x - 2, y - 2, x + w + 2, y + h + 2, GDP_C_ACCENT);
    GDP_CreateRectangle(GDP_BIL_PFX "Bg",     x,     y,     x + w,     y + h,     GDP_C_PANEL);
    GDP_CreateRectangle(GDP_BIL_PFX "TitleBar", x, y, x + w, y + 28, GDP_C_TITLE);

    GDP_CreateButton(GDP_BIL_PFX "DragHandle", x + 30, y + 3, w - 70, 22, "", GDP_C_TITLE);
    ObjectSetInteger(0, GDP_BIL_PFX "DragHandle", OBJPROP_BORDER_TYPE, BORDER_FLAT);

    GDP_CreateLabel(GDP_BIL_PFX "Title", x + 14, y + 7, GDP_T("BILAN DE TRADING", "TRADING REPORT"), GDP_C_WARN, 11);
    GDP_CreateButton(GDP_BIL_PFX "CloseBtn", x + w - 28, y + 4, 22, 20, "X", GDP_C_SELL);

    //--- selecteur de periode
    int btn_y = y + 36;
    int btn_w = 100;
    int gap   = 8;

    GDP_CreateButton(GDP_BIL_PFX "BtnDay",   x + 14,                   btn_y, btn_w, 24, GDP_T("JOUR", "DAY"),
                     period == GDP_PERIOD_DAY   ? GDP_C_ACCENT : GDP_C_NEUTRAL);
    GDP_CreateButton(GDP_BIL_PFX "BtnWeek",  x + 14 + (btn_w + gap),   btn_y, btn_w, 24, GDP_T("SEMAINE", "WEEK"),
                     period == GDP_PERIOD_WEEK  ? GDP_C_ACCENT : GDP_C_NEUTRAL);
    GDP_CreateButton(GDP_BIL_PFX "BtnMonth", x + 14 + 2*(btn_w + gap), btn_y, btn_w, 24, GDP_T("MOIS", "MONTH"),
                     period == GDP_PERIOD_MONTH ? GDP_C_ACCENT : GDP_C_NEUTRAL);

    ObjectSetInteger(0, GDP_BIL_PFX "BtnDay",   OBJPROP_COLOR, GDP_C_TEXT);
    ObjectSetInteger(0, GDP_BIL_PFX "BtnWeek",  OBJPROP_COLOR, GDP_C_TEXT);
    ObjectSetInteger(0, GDP_BIL_PFX "BtnMonth", OBJPROP_COLOR, GDP_C_TEXT);

    if(!ok)
    {
        GDP_CreateLabel(GDP_BIL_PFX "Err", x + 14, btn_y + 34,
                        GDP_T("Historique indisponible.", "History unavailable."), GDP_C_SELL, 9);
        ChartRedraw();
        return;
    }

    int cy = btn_y + 32;

    //--- entete : periode et soldes
    datetime from = GDP_BilanPeriodStart(period);
    GDP_CreateLabel(GDP_BIL_PFX "Period", x + 14, cy,
                    GDP_BilanPeriodLabel(period) + GDP_T(" · depuis le ", " · since ") +
                    TimeToString(from, TIME_DATE | TIME_MINUTES), GDP_C_TEXT_DIM, 9);
    cy += 16;

    GDP_CreateLabel(GDP_BIL_PFX "Balance", x + 14, cy,
                    GDP_T("Solde de départ $", "Starting balance $") + DoubleToString(start_balance, 2) +
                    GDP_T("   ->   actuel $", "   ->   now $") + DoubleToString(balance, 2), GDP_C_TEXT_DIM, 9);
    cy += 20;

    //--- P&L de la periode
    string sign     = (total_pnl >= 0) ? "+" : "";
    color  pnl_clr  = (total_pnl > 0) ? GDP_C_BUY : ((total_pnl < 0) ? GDP_C_SELL : GDP_C_TEXT_DIM);
    GDP_CreateLabel(GDP_BIL_PFX "Pnl", x + 14, cy,
                    "P&L " + sign + "$" + DoubleToString(total_pnl, 2) +
                    "  (" + sign + DoubleToString(pnl_pct, 2) + "%)", pnl_clr, 12);

    //--- compteur global et taux de reussite
    if(total_trades > 0)
    {
        double wr = (total_wins + total_losses > 0)
                  ? (total_wins * 100.0 / (total_wins + total_losses)) : 0.0;

        string recap = IntegerToString(total_wins) + "G / " + IntegerToString(total_losses) + "P";
        if(total_be > 0) recap += " / " + IntegerToString(total_be) + "BE";
        if(total_wins + total_losses > 0) recap += "   WR " + DoubleToString(wr, 1) + "%";

        GDP_CreateLabel(GDP_BIL_PFX "Recap", x + w - 175, cy + 3, recap, GDP_C_WARN, 10);
    }
    cy += 26;

    GDP_CreateRectangle(GDP_BIL_PFX "Sep", x + 14, cy, x + w - 14, cy + 1, GDP_C_NEUTRAL);
    cy += 8;

    //--- une ligne par instrument, en police a chasse fixe pour aligner les colonnes
    if(total_trades == 0)
    {
        GDP_CreateLabel(GDP_BIL_PFX "Empty", x + 14, cy,
                        GDP_T("Aucune position fermée sur cette période.", "No position closed over this period."), GDP_C_WARN, 9);
        ChartRedraw();
        return;
    }

    int max_rows = (h - (cy - y) - 12) / 16;

    for(int k = 0; k < n && k < max_rows; k++)
    {
        int    trades = stats[k].wins + stats[k].losses + stats[k].breakevens;
        double pct    = (start_balance > 0) ? (stats[k].net_pnl / start_balance) * 100.0 : 0.0;
        double wr     = (stats[k].wins + stats[k].losses > 0)
                      ? (stats[k].wins * 100.0 / (stats[k].wins + stats[k].losses)) : 0.0;

        string s_sign = (stats[k].net_pnl >= 0) ? "+" : "";

        string line = GDP_PadRight(stats[k].symbol, 14);
        string wl   = IntegerToString(stats[k].wins) + "G/" + IntegerToString(stats[k].losses) + "P";
        if(stats[k].breakevens > 0) wl += "/" + IntegerToString(stats[k].breakevens) + "BE";
        line += GDP_PadRight(wl, 11);
        line += GDP_PadRight(s_sign + "$" + DoubleToString(stats[k].net_pnl, 2), 12);
        line += GDP_PadRight("(" + s_sign + DoubleToString(pct, 2) + "%)", 11);
        if(stats[k].wins + stats[k].losses > 0) line += "WR " + DoubleToString(wr, 0) + "%";

        color row_clr = (stats[k].net_pnl > 0) ? GDP_C_BUY
                                               : ((stats[k].net_pnl < 0) ? GDP_C_SELL : GDP_C_TEXT_DIM);

        string nm = GDP_BIL_PFX "Row_" + IntegerToString(k);
        GDP_CreateLabel(nm, x + 14, cy, line, row_clr, 9);
        ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
        cy += 16;
    }

    if(n > max_rows)
        GDP_CreateLabel(GDP_BIL_PFX "More", x + 14, cy,
                        GDP_T("... ", "... ") + IntegerToString(n - max_rows) + GDP_T(" instrument(s) non affiché(s)", " instrument(s) not shown"),
                        GDP_C_TEXT_DIM, 8);

    ChartRedraw();
}

void GDP_ToggleBilan()
{
    if(gdp_bilan_visible) GDP_CloseBilan();
    else                  GDP_ShowBilan(gdp_bilan_period);
}

//+------------------------------------------------------------------+
//| JOURNAL - theme sombre partage avec le bilan                      |
//+------------------------------------------------------------------+
#define GDP_DARK_BG     GDP_C_PANEL
#define GDP_DARK_TITLE  GDP_C_TITLE
#define GDP_DARK_FIELD  GDP_C_FIELD

//--- champ de saisie sur fond sombre
void GDP_CreateEditDark(string name, int x, int y, int width, int height, string text)
{
    GDP_CreateEdit(name, x, y, width, height, text);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, GDP_DARK_FIELD);
    ObjectSetInteger(0, name, OBJPROP_COLOR, GDP_C_TEXT);
    ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, GDP_C_TEXT_DIM);
    ObjectSetInteger(0, name, OBJPROP_ALIGN, ALIGN_LEFT);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
}

//+------------------------------------------------------------------+
//| JOURNAL - fichiers et format CSV                                  |
//+------------------------------------------------------------------+
void GDP_EnsureJournalFolders()
{
    FolderCreate(GDP_JRN_FOLDER);
    FolderCreate(GDP_JRN_SNAPDIR);
}

//--- un champ CSV : guillemets doubles, separateur point-virgule (Excel FR)
string GDP_CsvEscape(string s)
{
    StringReplace(s, "\"", "\"\"");
    StringReplace(s, "\r", " ");
    StringReplace(s, "\n", " ");
    return "\"" + s + "\"";
}

//--- decoupe une ligne CSV en respectant les guillemets
int GDP_CsvSplit(string line, string &out[])
{
    ArrayResize(out, 0);

    string cur = "";
    bool   in_quotes = false;
    int    len = StringLen(line);

    for(int i = 0; i < len; i++)
    {
        ushort c = StringGetCharacter(line, i);

        if(in_quotes)
        {
            if(c == '"')
            {
                // deux guillemets consecutifs = un guillemet litteral
                if(i + 1 < len && StringGetCharacter(line, i + 1) == '"')
                {
                    cur += "\"";
                    i++;
                }
                else in_quotes = false;
            }
            else cur += ShortToString(c);
        }
        else
        {
            if(c == '"')      in_quotes = true;
            else if(c == ';') { int k = ArraySize(out); ArrayResize(out, k + 1); out[k] = cur; cur = ""; }
            else if(c == '\r' || c == '\n') continue;
            else cur += ShortToString(c);
        }
    }

    int k = ArraySize(out);
    ArrayResize(out, k + 1);
    out[k] = cur;
    return ArraySize(out);
}

//--- ajoute une entree a la fin du journal, en creant l'en-tete au premier appel
bool GDP_JournalAppend(GDP_JournalEntry &e)
{
    GDP_EnsureJournalFolders();

    int h = FileOpen(GDP_JRN_FILE, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
    if(h == INVALID_HANDLE)
    {
        Print("[GDP] Journal : impossible d'ouvrir ", GDP_JRN_FILE, " (err ", GetLastError(), ")");
        return false;
    }

    bool is_new = (FileSize(h) == 0);
    FileSeek(h, 0, SEEK_END);

    if(is_new)
        FileWriteString(h, "date;symbole;sens;type;entree;sl;tp;lots;risque_pct;rr;ticket;confiance;motifs;raisons;snapshot\r\n");

    string line = GDP_CsvEscape(e.stamp)      + ";" +
                  GDP_CsvEscape(e.symbol)     + ";" +
                  GDP_CsvEscape(e.direction)  + ";" +
                  GDP_CsvEscape(e.order_type) + ";" +
                  GDP_CsvEscape(e.entry)      + ";" +
                  GDP_CsvEscape(e.sl)         + ";" +
                  GDP_CsvEscape(e.tp)         + ";" +
                  GDP_CsvEscape(e.lots)       + ";" +
                  GDP_CsvEscape(e.risk)       + ";" +
                  GDP_CsvEscape(e.rr)         + ";" +
                  GDP_CsvEscape(e.ticket)     + ";" +
                  GDP_CsvEscape(e.conf)       + ";" +
                  GDP_CsvEscape(e.tags)       + ";" +
                  GDP_CsvEscape(e.reason)     + ";" +
                  GDP_CsvEscape(e.snap);

    FileWriteString(h, line + "\r\n");
    FileClose(h);
    return true;
}

//--- charge tout le journal en memoire (la plus recente en premier)
int GDP_JournalLoad(GDP_JournalEntry &arr[])
{
    ArrayResize(arr, 0);

    int h = FileOpen(GDP_JRN_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
    if(h == INVALID_HANDLE) return 0;

    bool first_line = true;

    while(!FileIsEnding(h))
    {
        string line = FileReadString(h);
        if(StringLen(line) < 2) continue;

        if(first_line) { first_line = false; continue; }   // en-tete

        string f[];
        if(GDP_CsvSplit(line, f) < 15) continue;

        int k = ArraySize(arr);
        ArrayResize(arr, k + 1);
        arr[k].stamp      = f[0];
        arr[k].symbol     = f[1];
        arr[k].direction  = f[2];
        arr[k].order_type = f[3];
        arr[k].entry      = f[4];
        arr[k].sl         = f[5];
        arr[k].tp         = f[6];
        arr[k].lots       = f[7];
        arr[k].risk       = f[8];
        arr[k].rr         = f[9];
        arr[k].ticket     = f[10];
        arr[k].conf       = f[11];
        arr[k].tags       = f[12];
        arr[k].reason     = f[13];
        arr[k].snap       = f[14];
    }

    FileClose(h);

    //--- inverser : on relit en partant du trade le plus recent
    int n = ArraySize(arr);
    for(int i = 0; i < n / 2; i++)
    {
        GDP_JournalEntry tmp = arr[i];
        arr[i]             = arr[n - 1 - i];
        arr[n - 1 - i]     = tmp;
    }

    return n;
}

//+------------------------------------------------------------------+
//| JOURNAL - capture du setup                                        |
//+------------------------------------------------------------------+
//  Les panneaux sont masques le temps de la capture : le snapshot doit
//  montrer le graphique et les lignes Entry/SL/TP, pas l'interface.
void GDP_SetPanelsHidden(bool hidden)
{
    long tf = hidden ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS;

    for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
    {
        string name = ObjectName(0, i);
        if(StringFind(name, "GDP_") != 0)      continue;
        if(StringFind(name, "GDP_LINE_") == 0) continue;   // les lignes du setup restent visibles

        ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, tf);
    }
}

//--- nettoie un nom de fichier des caracteres interdits
string GDP_SafeName(string s)
{
    string bad = "\\/:*?\"<>| ";
    for(int i = 0; i < StringLen(bad); i++)
        StringReplace(s, ShortToString(StringGetCharacter(bad, i)), "_");
    return s;
}

//--- capture le chart ; renvoie le chemin relatif a MQL5\Files, "" si echec
string GDP_TakeSnapshot()
{
    GDP_EnsureJournalFolders();

    string stamp = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
    StringReplace(stamp, ".", "");
    StringReplace(stamp, ":", "");
    StringReplace(stamp, " ", "_");

    string file = GDP_JRN_SNAPDIR + "\\" + GDP_SafeName(_Symbol) + "_" + stamp +
                  (GDP_SnapshotAsBMP ? ".bmp" : ".png");

    int w = (GDP_SnapshotWidth  > 100) ? GDP_SnapshotWidth  : 760;
    int h = (GDP_SnapshotHeight > 100) ? GDP_SnapshotHeight : 420;

    GDP_SetPanelsHidden(true);
    ChartRedraw();
    Sleep(80);                       // laisse le terminal redessiner avant la capture

    bool ok = ChartScreenShot(0, file, w, h, ALIGN_RIGHT);

    GDP_SetPanelsHidden(false);
    ChartRedraw();

    if(!ok)
    {
        Print("[GDP] Snapshot echoue (err ", GetLastError(), ")");
        return "";
    }
    return file;
}

//+------------------------------------------------------------------+
//| JOURNAL - saisie courante                                         |
//+------------------------------------------------------------------+
//--- relit les champs du panneau de saisie s'il est ouvert
void GDP_ReadJournalFields()
{
    if(!gdp_jrn_visible) return;

    for(int i = 0; i < GDP_JRN_LINES; i++)
    {
        string nm = GDP_JRN_PFX + "Reason" + IntegerToString(i);
        if(ObjectFind(0, nm) >= 0)
            gdp_jrn_reason[i] = ObjectGetString(0, nm, OBJPROP_TEXT);
    }
}

//--- les 3 lignes de saisie, mises bout a bout
string GDP_BuildReasonText()
{
    string out = "";
    for(int i = 0; i < GDP_JRN_LINES; i++)
    {
        string s = gdp_jrn_reason[i];
        StringTrimLeft(s);
        StringTrimRight(s);
        if(s == "") continue;
        if(out != "") out += " | ";
        out += s;
    }
    return out;
}

//--- les motifs selectionnes
string GDP_BuildTagText()
{
    string out = "";
    for(int i = 0; i < gdp_jrn_tag_count; i++)
    {
        if(!gdp_jrn_tag_on[i]) continue;
        if(out != "") out += ", ";
        out += gdp_jrn_tag_name[i];
    }
    return out;
}

void GDP_ClearJournalInputs()
{
    for(int i = 0; i < GDP_JRN_LINES; i++) gdp_jrn_reason[i] = "";
    for(int i = 0; i < gdp_jrn_tag_count; i++) gdp_jrn_tag_on[i] = false;
    gdp_jrn_conf = 0;
}

//+------------------------------------------------------------------+
//| JOURNAL - enregistrement d'une entree                             |
//+------------------------------------------------------------------+
//  Appele apres chaque ordre accepte, et par le bouton ENREGISTRER
//  (observation sans ordre : ticket et niveaux a vide).
void GDP_RecordEntry(string direction, string order_type, double entry,
                     double sl, double tp, double lots, ulong ticket)
{
    if(!GDP_JournalEnabled) return;

    GDP_ReadJournalFields();

    GDP_JournalEntry e;
    e.stamp      = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
    e.symbol     = _Symbol;
    e.direction  = direction;
    e.order_type = order_type;
    e.entry      = (entry > 0) ? DoubleToString(entry, _Digits) : "";
    e.sl         = (sl    > 0) ? DoubleToString(sl, _Digits)    : "";
    e.tp         = (tp    > 0) ? DoubleToString(tp, _Digits)    : "";
    e.lots       = (lots  > 0) ? DoubleToString(lots, 2)        : "";
    e.risk       = DoubleToString(gdp_risk_percent, 2);
    e.ticket     = (ticket > 0) ? IntegerToString((long)ticket) : "";
    e.conf       = (gdp_jrn_conf > 0) ? IntegerToString(gdp_jrn_conf) + "/5" : "";
    e.tags       = GDP_BuildTagText();
    e.reason     = GDP_BuildReasonText();

    double rr = GDP_CalculateRiskReward(entry, sl, tp);
    e.rr = (rr > 0) ? "1:" + DoubleToString(rr, 2) : "";

    e.snap = "";
    if(GDP_SnapshotOnOrder && gdp_jrn_snap_on)
        e.snap = GDP_TakeSnapshot();

    if(!GDP_JournalAppend(e))
    {
        GDP_SetStatus(GDP_T("Journal : écriture impossible (voir l'onglet Journal du terminal).", "Journal: write failed (see terminal Journal tab)."), GDP_C_SELL);
        return;
    }

    GDP_ClearJournalInputs();
    if(gdp_jrn_visible) GDP_ShowJournal();

    string suffix = (e.snap != "") ? " + snapshot" : "";
    GDP_SetStatus(GDP_T("Journal : entrée enregistrée", "Journal: entry saved") + suffix + ".", GDP_C_BUY);
}

//+------------------------------------------------------------------+
//| JOURNAL - panneau de saisie                                       |
//+------------------------------------------------------------------+
void GDP_CloseJournal()
{
    ObjectsDeleteAll(0, GDP_JRN_PFX);
    gdp_jrn_visible = false;
    ChartRedraw();
}

//  Somme exacte des increments poses par GDP_ShowJournal().
int GDP_JournalPanelHeight()
{
    int h = 34                        // barre de titre
          + 18                        // GDP_T("Pourquoi ce trade ?", "Why this trade?")
          + GDP_JRN_LINES * 24        // champs de saisie
          + 6;

    if(gdp_jrn_tag_count > 0)
        h += 20 + ((gdp_jrn_tag_count + 3) / 4) * 23 + 6;

    h += 30    // confiance
       + 28    // boutons d'action
       + 16    // ligne d'aide
       + 8;    // marge basse

    return h;
}

void GDP_ShowJournal()
{
    //--- on repart d'un panneau propre : les valeurs vivent dans les variables
    GDP_ReadJournalFields();
    ObjectsDeleteAll(0, GDP_JRN_PFX);
    gdp_jrn_visible = true;

    int x = gdp_jrn_x;
    int y = gdp_jrn_y;
    int w = gdp_jrn_width;
    int h = GDP_JournalPanelHeight();

    GDP_CreateRectangle(GDP_JRN_PFX "Border", x - 2, y - 2, x + w + 2, y + h + 2, GDP_C_ACCENT);
    GDP_CreateRectangle(GDP_JRN_PFX "Bg",     x,     y,     x + w,     y + h,     GDP_DARK_BG);
    GDP_CreateRectangle(GDP_JRN_PFX "TitleBar", x, y, x + w, y + 28, GDP_DARK_TITLE);

    GDP_CreateButton(GDP_JRN_PFX "DragHandle", x + 30, y + 3, w - 70, 22, "", GDP_DARK_TITLE);
    ObjectSetInteger(0, GDP_JRN_PFX "DragHandle", OBJPROP_BORDER_TYPE, BORDER_FLAT);

    GDP_CreateLabel(GDP_JRN_PFX "Title", x + 14, y + 7, GDP_T("JOURNAL DE TRADE", "TRADE JOURNAL"), GDP_C_WARN, 11);
    GDP_CreateButton(GDP_JRN_PFX "CloseBtn", x + w - 28, y + 4, 22, 20, "X", GDP_C_SELL);

    int cy = y + 34;
    int cx = x + 14;
    int field_w = w - 28;

    GDP_CreateLabel(GDP_JRN_PFX "Ask", cx, cy, "Pourquoi ce trade ?", GDP_C_TEXT_DIM, 9);
    cy += 18;

    for(int i = 0; i < GDP_JRN_LINES; i++)
    {
        GDP_CreateEditDark(GDP_JRN_PFX + "Reason" + IntegerToString(i),
                           cx, cy, field_w, 20, gdp_jrn_reason[i]);
        cy += 24;
    }

    cy += 6;

    //--- motifs cliquables
    if(gdp_jrn_tag_count > 0)
    {
        GDP_CreateLabel(GDP_JRN_PFX "LblTags", cx, cy, GDP_T("Motifs", "Reasons"), GDP_C_TEXT_DIM, 9);
        cy += 20;

        int bw = (field_w - 9) / 4;
        for(int i = 0; i < gdp_jrn_tag_count; i++)
        {
            int col = i % 4;
            int row = i / 4;

            string nm = GDP_JRN_PFX + "Tag" + IntegerToString(i);
            GDP_CreateButton(nm, cx + col * (bw + 3), cy + row * 23, bw, 20,
                             gdp_jrn_tag_name[i],
                             gdp_jrn_tag_on[i] ? GDP_C_ACCENT : GDP_C_NEUTRAL);
            ObjectSetInteger(0, nm, OBJPROP_COLOR, GDP_C_TEXT);
        }

        cy += ((gdp_jrn_tag_count + 3) / 4) * 23 + 6;
    }

    //--- confiance
    GDP_CreateLabel(GDP_JRN_PFX "LblConf", cx, cy + 3, GDP_T("Confiance", "Confidence"), GDP_C_TEXT_DIM, 9);
    for(int i = 1; i <= 5; i++)
    {
        string nm = GDP_JRN_PFX + "Conf" + IntegerToString(i);
        GDP_CreateButton(nm, cx + 80 + (i - 1) * 32, cy, 28, 20, IntegerToString(i),
                         (gdp_jrn_conf == i) ? GDP_C_WARN : GDP_C_NEUTRAL);
        ObjectSetInteger(0, nm, OBJPROP_COLOR, (gdp_jrn_conf == i) ? GDP_C_TITLE : GDP_C_TEXT);
    }
    cy += 30;

    //--- actions
    GDP_CreateButton(GDP_JRN_PFX "SnapToggle", cx, cy, 92, 24,
                     gdp_jrn_snap_on ? GDP_T("CAPTURE ON", "SNAPSHOT ON") : GDP_T("CAPTURE OFF", "SNAPSHOT OFF"),
                     gdp_jrn_snap_on ? GDP_C_BUY : GDP_C_NEUTRAL);
    ObjectSetInteger(0, GDP_JRN_PFX "SnapToggle", OBJPROP_COLOR, GDP_C_TEXT);

    GDP_CreateButton(GDP_JRN_PFX "SaveBtn", cx + 97, cy, 150, 24, GDP_T("ENREGISTRER", "SAVE"), GDP_C_ACCENT);
    ObjectSetInteger(0, GDP_JRN_PFX "SaveBtn", OBJPROP_COLOR, GDP_C_TEXT);

    GDP_CreateButton(GDP_JRN_PFX "ClearBtn", cx + 252, cy, 100, 24, GDP_T("EFFACER", "CLEAR"), GDP_C_NEUTRAL);
    ObjectSetInteger(0, GDP_JRN_PFX "ClearBtn", OBJPROP_COLOR, GDP_C_TEXT);
    cy += 28;

    GDP_CreateLabel(GDP_JRN_PFX "Hint", cx, cy,
                    GDP_T("Joint automatiquement au prochain ordre placé.", "Attached automatically to your next order."), GDP_C_TEXT_DIM, 8);

    ChartRedraw();
}

void GDP_ToggleJournal()
{
    if(gdp_jrn_visible) GDP_CloseJournal();
    else                GDP_ShowJournal();
}

//+------------------------------------------------------------------+
//| JOURNAL - panneau de revue                                        |
//+------------------------------------------------------------------+
void GDP_CloseReview()
{
    ObjectsDeleteAll(0, GDP_REV_PFX);
    gdp_rev_visible = false;
    ChartRedraw();
}

//--- coupe un texte en lignes d'au plus max_chars, sans casser les mots
int GDP_WrapText(string text, int max_chars, string &lines[], int max_lines)
{
    ArrayResize(lines, 0);
    if(text == "") return 0;

    string words[];
    int    wc = StringSplit(text, ' ', words);
    if(wc <= 0) { ArrayResize(lines, 1); lines[0] = text; return 1; }

    string cur = "";
    for(int i = 0; i < wc; i++)
    {
        string candidate = (cur == "") ? words[i] : cur + " " + words[i];

        if(StringLen(candidate) <= max_chars) { cur = candidate; continue; }

        int k = ArraySize(lines);
        if(k >= max_lines) { lines[k - 1] += " ..."; return k; }
        ArrayResize(lines, k + 1);
        lines[k] = cur;
        cur = words[i];
    }

    if(cur != "")
    {
        int k = ArraySize(lines);
        if(k < max_lines) { ArrayResize(lines, k + 1); lines[k] = cur; }
    }
    return ArraySize(lines);
}

void GDP_ShowReview(int index)
{
    ObjectsDeleteAll(0, GDP_REV_PFX);
    gdp_rev_visible = true;

    int total = ArraySize(gdp_rev_entries);
    if(total > 0)
    {
        if(index < 0)      index = 0;
        if(index >= total) index = total - 1;
    }
    gdp_rev_index = index;

    int snap_w = (GDP_SnapshotWidth  > 100) ? GDP_SnapshotWidth  : 760;
    int snap_h = (GDP_SnapshotHeight > 100) ? GDP_SnapshotHeight : 420;

    int w = snap_w + 28;
    if(w < 520) w = 520;

    int header_h = 180;
    int h = header_h + ((total > 0) ? snap_h + 12 : 40);

    int chart_h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
    if(gdp_rev_y + h > chart_h - 10) h = chart_h - 10 - gdp_rev_y;
    if(h < 220) h = 220;

    int x = gdp_rev_x;
    int y = gdp_rev_y;

    GDP_CreateRectangle(GDP_REV_PFX "Border", x - 2, y - 2, x + w + 2, y + h + 2, GDP_C_ACCENT);
    GDP_CreateRectangle(GDP_REV_PFX "Bg",     x,     y,     x + w,     y + h,     GDP_DARK_BG);
    GDP_CreateRectangle(GDP_REV_PFX "TitleBar", x, y, x + w, y + 28, GDP_DARK_TITLE);

    GDP_CreateButton(GDP_REV_PFX "DragHandle", x + 30, y + 3, w - 70, 22, "", GDP_DARK_TITLE);
    ObjectSetInteger(0, GDP_REV_PFX "DragHandle", OBJPROP_BORDER_TYPE, BORDER_FLAT);

    GDP_CreateLabel(GDP_REV_PFX "Title", x + 14, y + 7, GDP_T("REVUE DU JOURNAL", "JOURNAL REVIEW"), GDP_C_WARN, 11);
    GDP_CreateButton(GDP_REV_PFX "CloseBtn", x + w - 28, y + 4, 22, 20, "X", GDP_C_SELL);

    int cx = x + 14;
    int cy = y + 36;

    //--- navigation
    GDP_CreateButton(GDP_REV_PFX "Prev", cx, cy, 40, 22, "<<", GDP_C_NEUTRAL);
    ObjectSetInteger(0, GDP_REV_PFX "Prev", OBJPROP_COLOR, GDP_C_TEXT);
    GDP_CreateButton(GDP_REV_PFX "Next", cx + 44, cy, 40, 22, ">>", GDP_C_NEUTRAL);
    ObjectSetInteger(0, GDP_REV_PFX "Next", OBJPROP_COLOR, GDP_C_TEXT);

    GDP_CreateLabel(GDP_REV_PFX "Counter", cx + 96, cy + 4,
                    (total > 0) ? IntegerToString(index + 1) + " / " + IntegerToString(total)
                                : "0 / 0", GDP_C_TEXT, 10);

    GDP_CreateButton(GDP_REV_PFX "Reload", x + w - 110, cy, 96, 22, GDP_T("ACTUALISER", "REFRESH"), GDP_C_NEUTRAL);
    ObjectSetInteger(0, GDP_REV_PFX "Reload", OBJPROP_COLOR, GDP_C_TEXT);

    cy += 30;

    if(total == 0)
    {
        GDP_CreateLabel(GDP_REV_PFX "Empty", cx, cy,
                        GDP_T("Journal vide. Saisissez vos raisons puis placez un ordre.", "Journal empty. Write your reasons, then place an order."), GDP_C_WARN, 9);
        ChartRedraw();
        return;
    }

    //--- entete de l'entree
    string head = gdp_rev_entries[index].stamp + "   |   " +
                  gdp_rev_entries[index].symbol + "   |   " +
                  gdp_rev_entries[index].direction;
    if(gdp_rev_entries[index].order_type != "")
        head += " " + gdp_rev_entries[index].order_type;
    if(gdp_rev_entries[index].ticket != "")
        head += "   |   #" + gdp_rev_entries[index].ticket;

    GDP_CreateLabel(GDP_REV_PFX "Head", cx, cy, head, GDP_C_TEXT, 10);
    cy += 20;

    //--- niveaux
    string lv = "";
    if(gdp_rev_entries[index].entry != "") lv += GDP_T("Entrée ", "Entry ") + gdp_rev_entries[index].entry + "    ";
    if(gdp_rev_entries[index].sl    != "") lv += "SL " + gdp_rev_entries[index].sl + "    ";
    if(gdp_rev_entries[index].tp    != "") lv += "TP " + gdp_rev_entries[index].tp + "    ";
    if(gdp_rev_entries[index].lots  != "") lv += gdp_rev_entries[index].lots + GDP_T(" lots    ", " lots    ");
    if(gdp_rev_entries[index].risk  != "") lv += GDP_T("risque ", "risk ") + gdp_rev_entries[index].risk + "%    ";
    if(gdp_rev_entries[index].rr    != "") lv += "RR " + gdp_rev_entries[index].rr;
    if(lv == "") lv = GDP_T("Note sans ordre", "Note without order");

    GDP_CreateLabel(GDP_REV_PFX "Levels", cx, cy, lv, GDP_C_TEXT_DIM, 9);
    cy += 20;

    //--- confiance et motifs
    string meta = "";
    if(gdp_rev_entries[index].conf != "") meta += GDP_T("Confiance ", "Confidence ") + gdp_rev_entries[index].conf + "    ";
    if(gdp_rev_entries[index].tags != "") meta += gdp_rev_entries[index].tags;
    if(meta != "")
    {
        GDP_CreateLabel(GDP_REV_PFX "Meta", cx, cy, meta, GDP_C_WARN, 9);
    }
    cy += 22;

    //--- raisons, sur 3 lignes au plus
    GDP_CreateLabel(GDP_REV_PFX "LblReason", cx, cy, GDP_T("Raisons", "Reasons"), GDP_C_TEXT_DIM, 8);
    cy += 16;

    string reason = gdp_rev_entries[index].reason;
    if(reason == "") reason = GDP_T("(aucune raison saisie)", "(no reason recorded)");

    string rlines[];
    int rn = GDP_WrapText(reason, (w - 28) / 6, rlines, 3);
    for(int i = 0; i < rn; i++)
    {
        GDP_CreateLabel(GDP_REV_PFX + "Reason" + IntegerToString(i), cx, cy, rlines[i], GDP_C_TEXT, 9);
        cy += 15;
    }

    cy = y + header_h;

    //--- snapshot
    string snap = gdp_rev_entries[index].snap;
    if(snap == "")
    {
        GDP_CreateLabel(GDP_REV_PFX "NoSnap", cx, cy, GDP_T("Pas de capture pour cette entrée.", "No snapshot for this entry."), GDP_C_TEXT_DIM, 9);
        ChartRedraw();
        return;
    }

    //--- si le panneau a ete raccourci pour tenir dans le chart, on recadre l'image
    int avail_h = h - header_h - 8;
    int shown_h = (avail_h > 40 && avail_h < snap_h) ? avail_h : snap_h;

    string img = GDP_REV_PFX "Snap";
    if(ObjectCreate(0, img, OBJ_BITMAP_LABEL, 0, 0, 0))
    {
        ObjectSetInteger(0, img, OBJPROP_XDISTANCE, cx);
        ObjectSetInteger(0, img, OBJPROP_YDISTANCE, cy);
        ObjectSetInteger(0, img, OBJPROP_XSIZE, snap_w);
        ObjectSetInteger(0, img, OBJPROP_YSIZE, shown_h);
        ObjectSetInteger(0, img, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, img, OBJPROP_BACK, false);

        // OBJ_BITMAP_LABEL ne sait lire que le BMP : un PNG ne s'affichera pas ici
        if(!ObjectSetString(0, img, OBJPROP_BMPFILE, "\\Files\\" + snap))
        {
            ObjectDelete(0, img);
            GDP_CreateLabel(GDP_REV_PFX "NoSnap", cx, cy,
                            GDP_T("Capture non affichable ici : ", "Snapshot cannot be shown here: ") + snap, GDP_C_WARN, 9);
            GDP_CreateLabel(GDP_REV_PFX "NoSnap2", cx, cy + 16,
                            "(MQL5\\Files\\" + snap + ")", GDP_C_TEXT_DIM, 8);
        }
    }

    ChartRedraw();
}

void GDP_ToggleReview()
{
    if(gdp_rev_visible)
    {
        GDP_CloseReview();
        return;
    }

    int n = GDP_JournalLoad(gdp_rev_entries);
    if(n == 0) GDP_SetStatus(GDP_T("Journal vide : rien à revoir pour le moment.", "Journal empty: nothing to review yet."), GDP_C_NEUTRAL);

    GDP_ShowReview(0);
}

//+------------------------------------------------------------------+
//| NIVEAUX DE DEPART                                                 |
//+------------------------------------------------------------------+
//  Sans SL ni TP, il n'y a aucune ligne a saisir sur le chart : on pose
//  donc un SL et un TP indicatifs cote achat, que le trader deplace
//  ensuite a la souris (monter le SL au-dessus de l'entree = vente).
//  Retourne true si les niveaux ont pu etre poses.
bool GDP_InitDefaultLevels()
{
    if(gdp_stop_loss > 0) return true;   // deja definis

    double entry = gdp_pending_mode ? gdp_pending_price : gdp_entry_price;
    double pip   = GDP_PipSize(_Symbol);
    if(entry <= 0 || pip <= 0) return false;

    double dist_pips = GDP_DefaultSLPips;
    if(dist_pips <= 0)
    {
        dist_pips = GDP_GetATRPips();
        if(dist_pips <= 0) return false;   // ATR pas encore pret : on reessaiera
    }

    double dist = dist_pips * pip;
    gdp_stop_loss   = NormalizeDouble(entry - dist, _Digits);
    gdp_take_profit = NormalizeDouble(entry + dist * MathMax(GDP_DefaultRR, 0.1), _Digits);

    return true;
}

//+------------------------------------------------------------------+
//| CYCLE DE VIE                                                      |
//+------------------------------------------------------------------+
int OnInit()
{
    gdp_panel_x       = GDP_PanelX;
    gdp_panel_y       = GDP_PanelY;
    gdp_pos_x         = GDP_PanelX + gdp_panel_width + 10;
    gdp_pos_y         = GDP_PanelY;
    gdp_bilan_x       = GDP_PanelX + gdp_panel_width + 10;
    gdp_bilan_y       = GDP_PanelY + gdp_pos_height + 20;
    gdp_jrn_x         = GDP_PanelX + gdp_panel_width + 10;   // a droite du panneau principal
    gdp_jrn_y         = GDP_PanelY;
    gdp_rev_x         = GDP_PanelX + 40;
    gdp_rev_y         = GDP_PanelY + 40;

    //--- motifs cliquables du journal
    gdp_jrn_tag_count = 0;
    if(GDP_JournalEnabled && StringLen(GDP_JournalTags) > 0)
    {
        string parts[];
        int np = StringSplit(GDP_JournalTags, ',', parts);

        for(int i = 0; i < np && gdp_jrn_tag_count < GDP_JRN_MAX_TAGS; i++)
        {
            string t = parts[i];
            StringTrimLeft(t);
            StringTrimRight(t);
            if(t == "") continue;

            ArrayResize(gdp_jrn_tag_name, gdp_jrn_tag_count + 1);
            ArrayResize(gdp_jrn_tag_on,   gdp_jrn_tag_count + 1);
            gdp_jrn_tag_name[gdp_jrn_tag_count] = t;
            gdp_jrn_tag_on[gdp_jrn_tag_count]   = false;
            gdp_jrn_tag_count++;
        }
    }

    for(int i = 0; i < GDP_JRN_LINES; i++) gdp_jrn_reason[i] = "";
    gdp_jrn_snap_on = GDP_SnapshotOnOrder;

    if(GDP_JournalEnabled) GDP_EnsureJournalFolders();
    gdp_risk_percent  = GDP_RiskPercent;
    gdp_lines_visible = GDP_LinesOnStart;
    gdp_advanced      = GDP_AdvancedOnStart;

    gdp_trade.SetExpertMagicNumber(GDP_MagicNumber);
    gdp_trade.SetDeviationInPoints(GDP_Deviation);
    gdp_trade.SetTypeFillingBySymbol(_Symbol);

    gdp_atr_handle = iATR(_Symbol, PERIOD_CURRENT, GDP_ATRPeriod);
    if(gdp_atr_handle == INVALID_HANDLE)
        Print("[GDP] ATR indisponible : Vol $ / RR Vol a zero et SL par defaut non pose.");

    //--- valeurs de depart : entree au marche, SL/TP indicatifs
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    gdp_entry_price   = (bid + ask) / 2.0;
    gdp_pending_price = ask;

    GDP_InitDefaultLevels();

    ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
    ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);

    GDP_UpdateCalculations();
    GDP_CreatePanel();
    if(gdp_lines_visible) GDP_CreateLines();

    EventSetTimer(1);

    GDP_SetStatus(GDP_T("Prêt. Réglez le Stop Loss et le Take Profit, puis achetez ou vendez.", "Ready. Set stop loss and take profit, then buy or sell."), GDP_C_NEUTRAL);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    EventKillTimer();

    if(gdp_atr_handle != INVALID_HANDLE)
        IndicatorRelease(gdp_atr_handle);

    GDP_DeletePanelObjects();
    GDP_DeletePositionsPanel();
    GDP_CloseBilan();
    GDP_CloseJournal();
    GDP_CloseReview();
    GDP_DeleteLines();

    ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
    ChartRedraw();
}

void OnTimer()
{
    //--- le bilan se recalcule toutes les 5 secondes, jamais pendant un deplacement
    if(gdp_bilan_visible && !gdp_bilan_dragging)
    {
        gdp_bilan_refresh_countdown--;
        if(gdp_bilan_refresh_countdown <= 0)
            GDP_ShowBilan(gdp_bilan_period);   // remet le compteur a 5
    }

    if(!gdp_panel_visible || gdp_panel_minimized)
    {
        GDP_RefreshPositionsPanel();
        return;
    }

    //--- l'ATR n'est pas toujours pret a l'init : on repose les niveaux des que possible
    if(gdp_stop_loss <= 0 && GDP_InitDefaultLevels())
    {
        if(ObjectFind(0, GDP_PFX "StopEdit") >= 0)
            ObjectSetString(0, GDP_PFX "StopEdit", OBJPROP_TEXT, DoubleToString(gdp_stop_loss, _Digits));
        if(ObjectFind(0, GDP_PFX "TakeEdit") >= 0)
            ObjectSetString(0, GDP_PFX "TakeEdit", OBJPROP_TEXT, DoubleToString(gdp_take_profit, _Digits));
        GDP_RefreshLines();
    }

    //--- en mode marche, l'entree suit le prix courant
    if(!gdp_pending_mode)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        gdp_entry_price = (bid + ask) / 2.0;

        if(ObjectFind(0, GDP_PFX "EntryEdit") >= 0)
            ObjectSetString(0, GDP_PFX "EntryEdit", OBJPROP_TEXT, DoubleToString(gdp_entry_price, _Digits));

        if(gdp_lines_visible && ObjectFind(0, GDP_LINE_ENTRY) >= 0)
            ObjectSetDouble(0, GDP_LINE_ENTRY, OBJPROP_PRICE, gdp_entry_price);
    }

    GDP_UpdateCalculations();
    GDP_UpdatePanel();
    GDP_RefreshPositionsPanel();
}

//+------------------------------------------------------------------+
//| EVENEMENTS GRAPHIQUES                                             |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
    //=============== DEPLACEMENT DES PANNEAUX ===============
    if(id == CHARTEVENT_MOUSE_MOVE)
    {
        int mouse_x = (int)lparam;
        int mouse_y = (int)dparam;

        int chart_w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
        int chart_h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);

        if(gdp_panel_dragging)
        {
            int nx = mouse_x - gdp_drag_off_x;
            int ny = mouse_y - gdp_drag_off_y;
            if(nx < 0) nx = 0;
            if(ny < 0) ny = 0;
            if(nx + gdp_panel_width > chart_w) nx = chart_w - gdp_panel_width;
            if(ny + 30 > chart_h) ny = chart_h - 30;

            int dx = nx - gdp_panel_x;
            int dy = ny - gdp_panel_y;
            if(dx != 0 || dy != 0)
            {
                gdp_panel_x = nx;
                gdp_panel_y = ny;
                GDP_MoveAllObjects(dx, dy);
                ChartRedraw();
            }
        }

        if(gdp_pos_dragging)
        {
            int nx = mouse_x - gdp_pos_drag_off_x;
            int ny = mouse_y - gdp_pos_drag_off_y;
            if(nx < 0) nx = 0;
            if(ny < 0) ny = 0;
            if(nx + gdp_pos_width > chart_w) nx = chart_w - gdp_pos_width;
            if(ny + 30 > chart_h) ny = chart_h - 30;

            if(nx != gdp_pos_x || ny != gdp_pos_y)
            {
                gdp_pos_x = nx;
                gdp_pos_y = ny;
                GDP_CreatePositionsPanel();
            }
        }

        if(gdp_bilan_dragging)
        {
            int nx = mouse_x - gdp_bilan_drag_off_x;
            int ny = mouse_y - gdp_bilan_drag_off_y;
            if(nx < 0) nx = 0;
            if(ny < 0) ny = 0;
            if(nx + gdp_bilan_width > chart_w) nx = chart_w - gdp_bilan_width;
            if(ny + 30 > chart_h) ny = chart_h - 30;

            if(nx != gdp_bilan_x || ny != gdp_bilan_y)
            {
                gdp_bilan_x = nx;
                gdp_bilan_y = ny;
                GDP_ShowBilan(gdp_bilan_period);
            }
        }

        if(gdp_jrn_dragging)
        {
            int nx = mouse_x - gdp_jrn_drag_off_x;
            int ny = mouse_y - gdp_jrn_drag_off_y;
            if(nx < 0) nx = 0;
            if(ny < 0) ny = 0;
            if(nx + gdp_jrn_width > chart_w) nx = chart_w - gdp_jrn_width;
            if(ny + 30 > chart_h) ny = chart_h - 30;

            if(nx != gdp_jrn_x || ny != gdp_jrn_y)
            {
                gdp_jrn_x = nx;
                gdp_jrn_y = ny;
                GDP_ShowJournal();
            }
        }

        if(gdp_rev_dragging)
        {
            int nx = mouse_x - gdp_rev_drag_off_x;
            int ny = mouse_y - gdp_rev_drag_off_y;
            if(nx < 0) nx = 0;
            if(ny < 0) ny = 0;
            if(ny + 30 > chart_h) ny = chart_h - 30;

            if(nx != gdp_rev_x || ny != gdp_rev_y)
            {
                gdp_rev_x = nx;
                gdp_rev_y = ny;
                GDP_ShowReview(gdp_rev_index);
            }
        }
        return;
    }

    //=============== CLICS ===============
    if(id == CHARTEVENT_OBJECT_CLICK)
    {
        //--- poignees de deplacement
        if(sparam == GDP_PFX "DragHandle")
        {
            gdp_panel_dragging = true;
            gdp_drag_off_x = (int)lparam - gdp_panel_x;
            gdp_drag_off_y = (int)dparam - gdp_panel_y;
            ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
            return;
        }
        if(sparam == GDP_POS_PFX "DragHandle")
        {
            gdp_pos_dragging = true;
            gdp_pos_drag_off_x = (int)lparam - gdp_pos_x;
            gdp_pos_drag_off_y = (int)dparam - gdp_pos_y;
            ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
            return;
        }
        if(sparam == GDP_BIL_PFX "DragHandle")
        {
            gdp_bilan_dragging = true;
            gdp_bilan_drag_off_x = (int)lparam - gdp_bilan_x;
            gdp_bilan_drag_off_y = (int)dparam - gdp_bilan_y;
            ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
            return;
        }
        if(sparam == GDP_JRN_PFX "DragHandle")
        {
            gdp_jrn_dragging = true;
            gdp_jrn_drag_off_x = (int)lparam - gdp_jrn_x;
            gdp_jrn_drag_off_y = (int)dparam - gdp_jrn_y;
            ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
            return;
        }
        if(sparam == GDP_REV_PFX "DragHandle")
        {
            gdp_rev_dragging = true;
            gdp_rev_drag_off_x = (int)lparam - gdp_rev_x;
            gdp_rev_drag_off_y = (int)dparam - gdp_rev_y;
            ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
            return;
        }

        //--- un clic ailleurs termine le deplacement en cours
        if(gdp_panel_dragging || gdp_pos_dragging || gdp_bilan_dragging ||
           gdp_jrn_dragging   || gdp_rev_dragging)
        {
            gdp_panel_dragging = false;
            gdp_pos_dragging   = false;
            gdp_bilan_dragging = false;
            gdp_jrn_dragging   = false;
            gdp_rev_dragging   = false;
            ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
        }

        //--- barre de titre
        if(sparam == GDP_PFX "CloseWindowButton")      { GDP_ClosePanel();      return; }
        if(sparam == GDP_PFX "MinimizeButton")         { GDP_ToggleMinimize();  return; }
        if(sparam == GDP_PFX "ShowPanelButton")        { GDP_ShowPanelFunc();   return; }

        //--- modes : deux demi-boutons, un seul actif a la fois
        if(sparam == GDP_PFX "ModeMarket")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            if(gdp_pending_mode) GDP_TogglePendingMode();
            else                 GDP_RebuildPanel();
            return;
        }
        if(sparam == GDP_PFX "ModePending")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            if(!gdp_pending_mode) GDP_TogglePendingMode();
            else                  GDP_RebuildPanel();
            return;
        }
        if(sparam == GDP_PFX "AdvToggle")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            gdp_advanced = !gdp_advanced;
            GDP_RebuildPanel();
            return;
        }
        if(sparam == GDP_PFX "LinesButton")
        {
            GDP_ToggleLines();
            GDP_RebuildPanel();
            return;
        }
        if(sparam == GDP_PFX "ToolPositions")
        {
            gdp_pos_visible = !gdp_pos_visible;
            if(gdp_pos_visible) GDP_CreatePositionsPanel();
            else                GDP_DeletePositionsPanel();
            GDP_RebuildPanel();
            return;
        }
        if(sparam == GDP_PFX "ToolBilan")
        {
            GDP_ToggleBilan();
            GDP_RebuildPanel();
            return;
        }

        //--- panneau bilan
        if(sparam == GDP_BIL_PFX "CloseBtn")
        {
            GDP_CloseBilan();
            GDP_RebuildPanel();
            return;
        }
        if(sparam == GDP_BIL_PFX "BtnDay")   { GDP_ShowBilan(GDP_PERIOD_DAY);   return; }
        if(sparam == GDP_BIL_PFX "BtnWeek")  { GDP_ShowBilan(GDP_PERIOD_WEEK);  return; }
        if(sparam == GDP_BIL_PFX "BtnMonth") { GDP_ShowBilan(GDP_PERIOD_MONTH); return; }

        //--- journal : ouverture des panneaux
        if(sparam == GDP_PFX "ToolJournal")
        {
            GDP_ToggleJournal();
            GDP_RebuildPanel();
            return;
        }
        if(sparam == GDP_PFX "ToolReview")
        {
            GDP_ToggleReview();
            GDP_RebuildPanel();
            return;
        }

        //--- journal : panneau de saisie
        if(sparam == GDP_JRN_PFX "CloseBtn")
        {
            GDP_ReadJournalFields();      // on ne perd pas ce qui est tape
            GDP_CloseJournal();
            GDP_RebuildPanel();
            return;
        }
        if(sparam == GDP_JRN_PFX "SnapToggle")
        {
            GDP_ReadJournalFields();
            gdp_jrn_snap_on = !gdp_jrn_snap_on;
            GDP_ShowJournal();
            return;
        }
        if(sparam == GDP_JRN_PFX "ClearBtn")
        {
            GDP_ClearJournalInputs();
            GDP_ShowJournal();
            GDP_SetStatus(GDP_T("Journal : saisie effacée.", "Journal: input cleared."), GDP_C_NEUTRAL);
            return;
        }
        if(sparam == GDP_JRN_PFX "SaveBtn")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            GDP_ReadJournalFields();

            if(GDP_BuildReasonText() == "" && GDP_BuildTagText() == "")
            {
                GDP_SetStatus(GDP_T("Journal : rien à enregistrer (saisie vide).", "Journal: nothing to save (empty input)."), GDP_C_SELL);
                return;
            }

            // note libre : pas d'ordre, donc pas de niveaux ni de ticket
            GDP_RecordEntry("NOTE", "", 0, 0, 0, 0, 0);
            return;
        }
        if(StringFind(sparam, GDP_JRN_PFX "Tag") == 0)
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            int ti = (int)StringToInteger(StringSubstr(sparam, StringLen(GDP_JRN_PFX "Tag")));
            if(ti >= 0 && ti < gdp_jrn_tag_count)
            {
                GDP_ReadJournalFields();
                gdp_jrn_tag_on[ti] = !gdp_jrn_tag_on[ti];
                GDP_ShowJournal();
            }
            return;
        }
        if(StringFind(sparam, GDP_JRN_PFX "Conf") == 0)
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            int lvl = (int)StringToInteger(StringSubstr(sparam, StringLen(GDP_JRN_PFX "Conf")));
            GDP_ReadJournalFields();
            gdp_jrn_conf = (gdp_jrn_conf == lvl) ? 0 : lvl;   // reclic = annule
            GDP_ShowJournal();
            return;
        }

        //--- journal : panneau de revue
        if(sparam == GDP_REV_PFX "CloseBtn")
        {
            GDP_CloseReview();
            GDP_RebuildPanel();
            return;
        }
        if(sparam == GDP_REV_PFX "Prev")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            GDP_ShowReview(gdp_rev_index - 1);
            return;
        }
        if(sparam == GDP_REV_PFX "Next")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            GDP_ShowReview(gdp_rev_index + 1);
            return;
        }
        if(sparam == GDP_REV_PFX "Reload")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            GDP_JournalLoad(gdp_rev_entries);
            GDP_ShowReview(0);
            return;
        }

        //--- type d'ordre en attente
        if(sparam == GDP_PFX "BuyLimitButton")  { gdp_pending_type = ORDER_TYPE_BUY_LIMIT;  GDP_RebuildPanel(); return; }
        if(sparam == GDP_PFX "BuyStopButton")   { gdp_pending_type = ORDER_TYPE_BUY_STOP;   GDP_RebuildPanel(); return; }
        if(sparam == GDP_PFX "SellLimitButton") { gdp_pending_type = ORDER_TYPE_SELL_LIMIT; GDP_RebuildPanel(); return; }
        if(sparam == GDP_PFX "SellStopButton")  { gdp_pending_type = ORDER_TYPE_SELL_STOP;  GDP_RebuildPanel(); return; }

        //--- execution
        if(sparam == GDP_PFX "BuyButton")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            GDP_OpenMarketPosition(ORDER_TYPE_BUY);
            return;
        }
        if(sparam == GDP_PFX "SellButton")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            GDP_OpenMarketPosition(ORDER_TYPE_SELL);
            return;
        }
        if(sparam == GDP_PFX "PlaceButton")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            GDP_PlacePendingOrder();
            return;
        }
        if(sparam == GDP_PFX "CloseAllButton")
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            GDP_CloseAll();
            return;
        }

        //--- panneau positions
        if(sparam == GDP_POS_PFX "CloseButton")
        {
            gdp_pos_visible = false;
            GDP_DeletePositionsPanel();
            GDP_RebuildPanel();
            return;
        }
        if(StringFind(sparam, GDP_POS_PFX "BE_") == 0)
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(GDP_POS_PFX "BE_")));

            if(GDP_IsPositionAtBEPlus(ticket))
                GDP_SetStatus("Position #" + IntegerToString((long)ticket) + GDP_T(" déjà au seuil de rentabilité.", " already at break-even."), GDP_C_NEUTRAL);
            else
                GDP_SetBreakeven(ticket);
            return;
        }
        if(StringFind(sparam, GDP_POS_PFX "Close_") == 0)
        {
            ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
            ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(GDP_POS_PFX "Close_")));
            GDP_ClosePositionByTicket(ticket);
            return;
        }

        return;
    }

    //=============== FIN DE DEPLACEMENT ===============
    if(id == CHARTEVENT_CHART_CHANGE)
    {
        if(gdp_panel_dragging || gdp_pos_dragging || gdp_bilan_dragging ||
           gdp_jrn_dragging   || gdp_rev_dragging)
        {
            gdp_panel_dragging = false;
            gdp_pos_dragging   = false;
            gdp_bilan_dragging = false;
            gdp_jrn_dragging   = false;
            gdp_rev_dragging   = false;
            ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
        }
        return;
    }

    //=============== LIGNE DEPLACEE ===============
    if(id == CHARTEVENT_OBJECT_DRAG)
    {
        if(gdp_lines_visible) GDP_HandleLineDrag(sparam);
        return;
    }

    //=============== SAISIE VALIDEE DANS UN CHAMP ===============
    if(id == CHARTEVENT_OBJECT_ENDEDIT)
    {
        //--- champs du journal : on memorise la saisie, rien a recalculer
        if(StringFind(sparam, GDP_JRN_PFX "Reason") == 0)
        {
            GDP_ReadJournalFields();
            return;
        }

        if(sparam == GDP_PFX "EntryEdit")
        {
            if(gdp_pending_mode)
            {
                double v = StringToDouble(ObjectGetString(0, GDP_PFX "EntryEdit", OBJPROP_TEXT));
                if(v > 0) gdp_pending_price = v;
            }
            else
            {
                // Champ non editable en mode marche : on restaure le prix courant
                ObjectSetString(0, GDP_PFX "EntryEdit", OBJPROP_TEXT, DoubleToString(gdp_entry_price, _Digits));
            }
        }
        else if(sparam == GDP_PFX "StopEdit")
        {
            gdp_stop_loss = StringToDouble(ObjectGetString(0, GDP_PFX "StopEdit", OBJPROP_TEXT));
        }
        else if(sparam == GDP_PFX "TakeEdit")
        {
            gdp_take_profit = StringToDouble(ObjectGetString(0, GDP_PFX "TakeEdit", OBJPROP_TEXT));
        }
        else if(sparam == GDP_PFX "RiskEdit")
        {
            double v = StringToDouble(ObjectGetString(0, GDP_PFX "RiskEdit", OBJPROP_TEXT));
            if(v > 0) gdp_risk_percent = v;
            ObjectSetString(0, GDP_PFX "RiskEdit", OBJPROP_TEXT, DoubleToString(gdp_risk_percent, 2));
        }
        else
        {
            return;
        }

        GDP_UpdateCalculations();
        GDP_UpdatePanel();
        GDP_RefreshLines();
        return;
    }
}
//+------------------------------------------------------------------+
