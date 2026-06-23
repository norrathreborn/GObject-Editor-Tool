#include "Chat.h"
#include "Common.h"
#include "Config.h"
#include "Creature.h"
#include "DatabaseEnv.h"
#include "DBCStores.h"
#include "GameObject.h"
#include "GameObjectData.h"
#include "Language.h"
#include "Log.h"
#include "Map.h"
#include "MapMgr.h"
#include "ObjectAccessor.h"
#include "ObjectGuid.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "Unit.h"
#include "WorldPacket.h"
#include "WorldSession.h"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <limits>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace
{
constexpr char GE_PREFIX[] = "GE";
constexpr char GE_ACCESS_REQUEST[] = "HELLO:GOBJECT_EDITOR_ACCESS";
constexpr char GE_ACCESS_VERIFIED[] = "HELLO:GOBJECT_EDITOR_ACCESS_VERIFIED";
constexpr char GE_ACCESS_DENIED[] = "HELLO:GOBJECT_EDITOR_ACCESS_DENIED:GM_ACCESS_REQUIRED";

struct ObjectTransform
{
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
    float o = 0.0f;
    float r0 = 0.0f;
    float r1 = 0.0f;
    float r2 = 0.0f;
    float r3 = 1.0f;
};

struct SelectedObject
{
    uint32 guid = 0;
    uint32 entry = 0;
    std::string name;
    uint32 map = 0;

    ObjectTransform current;
    ObjectTransform previous;
    ObjectTransform lastSaved;
    ObjectTransform restorePosition;
    std::vector<ObjectTransform> undoHistory;

    bool hasSelection = false;
    bool hasUndo = false;
    bool hasRestore = false;
    bool dirty = false;

    ObjectGuid previewGuid = ObjectGuid::Empty;
};

struct ScanCandidate
{
    uint32 guid = 0;
    uint32 entry = 0;
    std::string name;
    uint32 map = 0;
    ObjectTransform transform;
    float distance = 0.0f;
    bool isCreature = false;
};

struct TemplateSearchRow
{
    uint32 entry = 0;
    uint32 type = 0;
    uint32 displayId = 0;
    std::string modelPath;
    std::string name;
};

struct CreatureTemplateSearchRow
{
    uint32 entry = 0;
    uint32 type = 0;
    uint32 displayId = 0;
    std::string displayIds;
    std::string name;
};

struct CreatureTransform
{
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
    float o = 0.0f;
};

struct CreatureEditState
{
    CreatureTransform original;
    CreatureTransform saved;
    std::vector<CreatureTransform> undoHistory;
    bool hasOriginal = false;
    bool hasSaved = false;
};

std::unordered_map<uint64, SelectedObject> SelectedByPlayer;
std::unordered_map<uint64, std::unordered_set<uint32>> LastScanGuidsByPlayer;
std::unordered_map<uint64, std::unordered_set<uint32>> LastScanCreatureGuidsByPlayer;
std::unordered_map<uint64, uint32> LastPlacedCreatureGuidByPlayer;
std::unordered_map<uint64, std::unordered_map<uint32, CreatureEditState>> CreatureEditStateByPlayer;

static bool IsModuleEnabled()
{
    return sConfigMgr->GetOption<bool>("GObjectEditor.Enable", true);
}

static bool IsDebugEnabled()
{
    return sConfigMgr->GetOption<bool>("GObjectEditor.Debug", false);
}

static uint32 RequiredSecurity()
{
    return sConfigMgr->GetOption<uint32>("GObjectEditor.RequiredSecurity", 3);
}

static float MaxScanDistance()
{
    return sConfigMgr->GetOption<float>("GObjectEditor.MaxScanDistance", 50.0f);
}

static uint32 SelectionPreviewDurationSeconds()
{
    return sConfigMgr->GetOption<uint32>("GObjectEditor.SelectionPreviewDurationSeconds", 3600);
}

static float MaxNudgeDistance()
{
    return sConfigMgr->GetOption<float>("GObjectEditor.MaxNudgeDistance", 5.0f);
}

static bool HasAccess(Player* player)
{
    if (!player || !player->GetSession())
        return false;

    if (!IsModuleEnabled())
        return false;

    return uint32(player->GetSession()->GetSecurity()) >= RequiredSecurity();
}

static std::string EscapePayloadString(std::string value)
{
    for (char& c : value)
    {
        if (c == '\t' || c == '\n' || c == '\r' || c == '|')
            c = ' ';
    }
    return value;
}

static std::string Trim(std::string value)
{
    size_t const first = value.find_first_not_of(" \t\n\r");
    if (first == std::string::npos)
        return "";

    size_t const last = value.find_last_not_of(" \t\n\r");
    return value.substr(first, last - first + 1);
}

static std::string FloatToString(float value)
{
    std::ostringstream ss;
    ss << std::fixed << std::setprecision(4) << value;
    return ss.str();
}

static WorldPacket CreateAddonPacket(std::string const& prefix, std::string const& message, ChatMsg messageType, Player* player)
{
    WorldPacket data;
    std::string fullMessage = prefix + "\t" + message;
    size_t messageLength = fullMessage.length();

    data.Initialize(SMSG_MESSAGECHAT, 1 + 4 + 8 + 4 + 8 + 4 + 1 + messageLength + 1);
    data << uint8(messageType);
    data << uint32(LANG_ADDON);
    data << uint64(player->GetGUID().GetRawValue());
    data << uint32(0);
    data << uint64(player->GetGUID().GetRawValue());
    data << uint32(messageLength + 1);
    data << fullMessage;
    data << uint8(0);

    return data;
}

static void SendAddonPayload(Player* player, std::string const& payload)
{
    if (!player || !player->GetSession())
        return;

    WorldPacket packet = CreateAddonPacket(GE_PREFIX, payload, CHAT_MSG_WHISPER, player);
    player->SendDirectMessage(&packet);
}

static void SendUndoStatus(Player* player, SelectedObject const& selected)
{
    if (!selected.hasSelection || selected.undoHistory.empty())
        SendAddonPayload(player, "UNDO_STATUS:ORIGINAL:0");
    else
        SendAddonPayload(player, "UNDO_STATUS:AVAILABLE:" + std::to_string(selected.undoHistory.size()));
}

static bool ParsePrefixedAddonMessage(std::string const& msg, std::string& payload)
{
    std::string expectedPrefix = std::string(GE_PREFIX) + "\t";
    if (msg.rfind(expectedPrefix, 0) != 0)
        return false;

    payload = msg.substr(expectedPrefix.length());
    return true;
}

static std::vector<std::string> Split(std::string const& input, char delimiter)
{
    std::vector<std::string> parts;
    std::stringstream ss(input);
    std::string item;
    while (std::getline(ss, item, delimiter))
        parts.push_back(item);
    return parts;
}

static float NormalizeAngle(float angle)
{
    while (angle < 0.0f)
        angle += static_cast<float>(M_PI * 2.0);
    while (angle >= static_cast<float>(M_PI * 2.0))
        angle -= static_cast<float>(M_PI * 2.0);
    return angle;
}

static void NormalizeQuaternion(ObjectTransform& transform)
{
    float const length = std::sqrt(transform.r0 * transform.r0 + transform.r1 * transform.r1 +
                                   transform.r2 * transform.r2 + transform.r3 * transform.r3);

    if (length <= 0.000001f)
    {
        float const half = transform.o * 0.5f;
        transform.r0 = 0.0f;
        transform.r1 = 0.0f;
        transform.r2 = std::sin(half);
        transform.r3 = std::cos(half);
        return;
    }

    transform.r0 /= length;
    transform.r1 /= length;
    transform.r2 /= length;
    transform.r3 /= length;
}

static void ApplyQuaternionDelta(ObjectTransform& transform, float axisX, float axisY, float axisZ, float deltaDegrees)
{
    float const axisLength = std::sqrt(axisX * axisX + axisY * axisY + axisZ * axisZ);
    if (axisLength <= 0.000001f)
        return;

    axisX /= axisLength;
    axisY /= axisLength;
    axisZ /= axisLength;

    float const deltaRadians = deltaDegrees * static_cast<float>(M_PI) / 180.0f;
    float const half = deltaRadians * 0.5f;
    float const sinHalf = std::sin(half);

    float const dx = axisX * sinHalf;
    float const dy = axisY * sinHalf;
    float const dz = axisZ * sinHalf;
    float const dw = std::cos(half);

    float const qx = transform.r0;
    float const qy = transform.r1;
    float const qz = transform.r2;
    float const qw = transform.r3;

    // Apply the delta in world-axis space: q' = delta * q.
    transform.r0 = (dw * qx) + (dx * qw) + (dy * qz) - (dz * qy);
    transform.r1 = (dw * qy) - (dx * qz) + (dy * qw) + (dz * qx);
    transform.r2 = (dw * qz) + (dx * qy) - (dy * qx) + (dz * qw);
    transform.r3 = (dw * qw) - (dx * qx) - (dy * qy) - (dz * qz);

    NormalizeQuaternion(transform);
}

static void ApplyAxisRotation(ObjectTransform& transform, std::string const& axis, float deltaDegrees)
{
    if (axis == "YAW")
    {
        transform.o = NormalizeAngle(transform.o + deltaDegrees * static_cast<float>(M_PI) / 180.0f);
        ApplyQuaternionDelta(transform, 0.0f, 0.0f, 1.0f, deltaDegrees);
    }
    else if (axis == "PITCH")
        ApplyQuaternionDelta(transform, 1.0f, 0.0f, 0.0f, deltaDegrees);
    else if (axis == "ROLL")
        ApplyQuaternionDelta(transform, 0.0f, 1.0f, 0.0f, deltaDegrees);
}

static std::string GetGameObjectName(uint32 entry)
{
    if (GameObjectTemplate const* info = sObjectMgr->GetGameObjectTemplate(entry))
        return info->name;

    return "Unknown";
}


static std::string GetCreatureName(uint32 entry)
{
    if (CreatureTemplate const* info = sObjectMgr->GetCreatureTemplate(entry))
        return info->Name;

    return "Unknown";
}


static std::string GetGameObjectModelPath(uint32 displayId)
{
    if (!displayId)
        return "";

    if (GameObjectDisplayInfoEntry const* info = sGameObjectDisplayInfoStore.LookupEntry(displayId))
    {
        if (info->filename)
            return info->filename;
    }

    return "";
}

static bool GetObjectData(uint32 guid, ScanCandidate& out)
{
    GameObjectData const* data = sObjectMgr->GetGameObjectData(guid);
    if (!data)
        return false;

    out.guid = guid;
    out.entry = data->id;
    out.name = GetGameObjectName(data->id);
    out.map = data->mapid;
    out.transform.x = data->posX;
    out.transform.y = data->posY;
    out.transform.z = data->posZ;
    out.transform.o = data->orientation;
    out.transform.r0 = data->rotation.x;
    out.transform.r1 = data->rotation.y;
    out.transform.r2 = data->rotation.z;
    out.transform.r3 = data->rotation.w;
    out.distance = 0.0f;
    return true;
}

static bool GetCreatureData(uint32 guid, ScanCandidate& out)
{
    CreatureData const* data = sObjectMgr->GetCreatureData(guid);
    if (!data)
        return false;

    out.guid = guid;
    out.entry = data->id1;
    out.name = GetCreatureName(data->id1);
    out.map = data->mapid;
    out.transform.x = data->posX;
    out.transform.y = data->posY;
    out.transform.z = data->posZ;
    out.transform.o = data->orientation;
    out.transform.r0 = 0.0f;
    out.transform.r1 = 0.0f;
    out.transform.r2 = 0.0f;
    out.transform.r3 = 1.0f;
    out.distance = 0.0f;
    out.isCreature = true;
    return true;
}

static std::string BuildObjectPayload(char const* opcode, ScanCandidate const& object)
{
    std::ostringstream ss;
    ss << opcode
       << ":" << object.guid
       << ":" << object.entry
       << ":" << object.map
       << ":" << FloatToString(object.transform.x)
       << ":" << FloatToString(object.transform.y)
       << ":" << FloatToString(object.transform.z)
       << ":" << FloatToString(object.transform.o)
       << ":" << FloatToString(object.distance)
       << ":" << EscapePayloadString(object.name);
    return ss.str();
}

static std::string BuildTemplateSearchPayload(TemplateSearchRow const& row)
{
    std::ostringstream ss;
    ss << "GOBJECT_TEMPLATE"
       << ":" << row.entry
       << ":" << row.type
       << ":" << row.displayId
       << ":" << EscapePayloadString(row.modelPath)
       << ":" << EscapePayloadString(row.name);
    return ss.str();
}

static uint32 GetFirstDisplayIdFromList(std::string const& displayIds)
{
    if (displayIds.empty())
        return 0;

    size_t comma = displayIds.find(',');
    std::string first = comma == std::string::npos ? displayIds : displayIds.substr(0, comma);
    first = Trim(first);

    if (first.empty() || first.find_first_not_of("0123456789") != std::string::npos)
        return 0;

    uint64 value = 0;
    for (char c : first)
    {
        value = (value * 10) + uint64(c - '0');
        if (value > std::numeric_limits<uint32>::max())
            return 0;
    }

    return uint32(value);
}

static std::string BuildCreatureTemplateSearchPayload(CreatureTemplateSearchRow const& row)
{
    std::ostringstream ss;
    ss << "CREATURE_TEMPLATE"
       << ":" << row.entry
       << ":" << row.type
       << ":" << row.displayId
       << ":" << EscapePayloadString(row.displayIds)
       << ":" << EscapePayloadString(row.name);
    return ss.str();
}

static std::string BuildSelectedPayload(char const* opcode, SelectedObject const& object)
{
    std::ostringstream ss;
    ss << opcode
       << ":" << object.guid
       << ":" << object.entry
       << ":" << object.map
       << ":" << FloatToString(object.current.x)
       << ":" << FloatToString(object.current.y)
       << ":" << FloatToString(object.current.z)
       << ":" << FloatToString(object.current.o)
       << ":0.0000"
       << ":" << EscapePayloadString(object.name);
    return ss.str();
}

static SelectedObject ToSelectedObject(ScanCandidate const& candidate)
{
    SelectedObject selected;
    selected.guid = candidate.guid;
    selected.entry = candidate.entry;
    selected.name = candidate.name;
    selected.map = candidate.map;
    selected.current = candidate.transform;
    selected.previous = candidate.transform;
    selected.lastSaved = candidate.transform;
    selected.restorePosition = candidate.transform;
    selected.hasSelection = true;
    selected.hasUndo = false;
    selected.hasRestore = false;
    selected.dirty = false;
    return selected;
}

static std::vector<ScanCandidate> BuildScan(Player* player, float distance)
{
    std::vector<ScanCandidate> rows;
    if (!player)
        return rows;

    distance = std::max(1.0f, std::min(distance, MaxScanDistance()));

    float const px = player->GetPositionX();
    float const py = player->GetPositionY();
    uint32 const mapId = player->GetMapId();

    for (auto const& pair : sObjectMgr->GetAllGOData())
    {
        uint32 const guid = pair.first;
        GameObjectData const& go = pair.second;

        if (go.mapid != mapId)
            continue;

        float const dx = go.posX - px;
        float const dy = go.posY - py;
        float const dist = std::sqrt(dx * dx + dy * dy);
        if (dist > distance)
            continue;

        ScanCandidate candidate;
        candidate.guid = guid;
        candidate.entry = go.id;
        candidate.name = GetGameObjectName(go.id);
        candidate.map = go.mapid;
        candidate.transform.x = go.posX;
        candidate.transform.y = go.posY;
        candidate.transform.z = go.posZ;
        candidate.transform.o = go.orientation;
        candidate.transform.r0 = go.rotation.x;
        candidate.transform.r1 = go.rotation.y;
        candidate.transform.r2 = go.rotation.z;
        candidate.transform.r3 = go.rotation.w;
        candidate.distance = dist;
        candidate.isCreature = false;
        rows.push_back(candidate);
    }

    for (auto const& pair : sObjectMgr->GetAllCreatureData())
    {
        uint32 const guid = uint32(pair.first);
        CreatureData const& creature = pair.second;

        if (creature.mapid != mapId)
            continue;

        float const dx = creature.posX - px;
        float const dy = creature.posY - py;
        float const dist = std::sqrt(dx * dx + dy * dy);
        if (dist > distance)
            continue;

        ScanCandidate candidate;
        candidate.guid = guid;
        candidate.entry = creature.id1;
        candidate.name = GetCreatureName(creature.id1);
        candidate.map = creature.mapid;
        candidate.transform.x = creature.posX;
        candidate.transform.y = creature.posY;
        candidate.transform.z = creature.posZ;
        candidate.transform.o = creature.orientation;
        candidate.transform.r0 = 0.0f;
        candidate.transform.r1 = 0.0f;
        candidate.transform.r2 = 0.0f;
        candidate.transform.r3 = 1.0f;
        candidate.distance = dist;
        candidate.isCreature = true;
        rows.push_back(candidate);
    }

    std::sort(rows.begin(), rows.end(), [](ScanCandidate const& a, ScanCandidate const& b) {
        return a.distance < b.distance;
    });

    if (rows.size() > 50)
        rows.resize(50);

    return rows;
}

static void DespawnSelectionPreview(Player* player, SelectedObject& selected)
{
    if (!player || selected.previewGuid.IsEmpty())
        return;

    if (GameObject* preview = ObjectAccessor::GetGameObject(*player, selected.previewGuid))
        preview->DespawnOrUnsummon();

    selected.previewGuid.Clear();
}

static void SpawnSelectionPreview(Player* player, SelectedObject& selected)
{
    if (!player || !selected.hasSelection)
        return;

    DespawnSelectionPreview(player, selected);

    if (!sObjectMgr->GetGameObjectTemplate(selected.entry))
    {
        SendAddonPayload(player, "PREVIEW:ERROR:GAMEOBJECT_TEMPLATE_NOT_FOUND:" + std::to_string(selected.entry));
        return;
    }

    uint32 const durationSeconds = std::max<uint32>(1, SelectionPreviewDurationSeconds());

    if (GameObject* preview = player->SummonGameObject(
            selected.entry,
            selected.current.x,
            selected.current.y,
            selected.current.z,
            selected.current.o,
            selected.current.r0, selected.current.r1, selected.current.r2, selected.current.r3,
            durationSeconds,
            false,
            GO_SUMMON_TIMED_DESPAWN))
    {
        selected.previewGuid = preview->GetGUID();
        SendAddonPayload(player, "PREVIEW:ACTIVE:" + std::to_string(selected.guid));
    }
    else
        SendAddonPayload(player, "PREVIEW:ERROR:GAMEOBJECT_SUMMON_FAILED");
}

static bool SpawnPlacedGameObject(Player* player, uint32 entry, ScanCandidate& out)
{
    if (!player || !entry)
        return false;

    GameObjectTemplate const* objectInfo = sObjectMgr->GetGameObjectTemplate(entry);
    if (!objectInfo)
    {
        SendAddonPayload(player, "PLACE_FAIL:GAMEOBJECT_TEMPLATE_NOT_FOUND:" + std::to_string(entry));
        return false;
    }

    if (objectInfo->displayId && !sGameObjectDisplayInfoStore.LookupEntry(objectInfo->displayId))
    {
        SendAddonPayload(player, "PLACE_FAIL:GAMEOBJECT_DISPLAY_INFO_NOT_FOUND:" + std::to_string(objectInfo->displayId));
        return false;
    }

    Map* map = player->GetMap();
    if (!map)
    {
        SendAddonPayload(player, "PLACE_FAIL:MAP_NOT_AVAILABLE");
        return false;
    }

    // GameObject placement uses a short forward offset so the object is visible and easier to edit.
    float const orientation = player->GetOrientation();
    float const placeDistance = 2.0f;
    float const x = player->GetPositionX() + std::cos(orientation) * placeDistance;
    float const y = player->GetPositionY() + std::sin(orientation) * placeDistance;
    float const z = player->GetPositionZ();
    uint32 const phaseMask = player->GetPhaseMask();

    if (!MapMgr::IsValidMapCoord(player->GetMapId(), x, y, z))
    {
        SendAddonPayload(player, "PLACE_FAIL:INVALID_MAP_COORDINATES");
        return false;
    }

    GameObject* object = new GameObject();
    ObjectGuid::LowType guidLow = map->GenerateLowGuid<HighGuid::GameObject>();

    if (!object->Create(guidLow, objectInfo->entry, map, phaseMask, x, y, z, orientation, G3D::Quat(), 0, GO_STATE_READY))
    {
        delete object;
        SendAddonPayload(player, "PLACE_FAIL:GAMEOBJECT_CREATE_FAILED");
        return false;
    }

    object->SaveToDB(map->GetId(), (1 << map->GetSpawnMode()), phaseMask);
    guidLow = object->GetSpawnId();

    delete object;

    object = new GameObject();
    if (!object->LoadGameObjectFromDB(guidLow, map, true))
    {
        delete object;
        SendAddonPayload(player, "PLACE_FAIL:GAMEOBJECT_LOAD_FROM_DB_FAILED:" + std::to_string(uint32(guidLow)));
        return false;
    }

    sObjectMgr->AddGameobjectToGrid(uint32(guidLow), sObjectMgr->GetGameObjectData(uint32(guidLow)));

    if (!GetObjectData(uint32(guidLow), out))
    {
        SendAddonPayload(player, "PLACE_FAIL:GAMEOBJECT_DATA_NOT_FOUND_AFTER_SPAWN:" + std::to_string(uint32(guidLow)));
        return false;
    }

    return true;
}


static bool DeleteGameObjectByDbGuid(Player* player, uint32 guid, std::string& deletedName)
{
    if (!player || !guid)
        return false;

    GameObjectData const* data = sObjectMgr->GetGameObjectData(guid);
    if (!data)
    {
        SendAddonPayload(player, "DELETE_FAIL:GAMEOBJECT_DATA_NOT_FOUND:" + std::to_string(guid));
        return false;
    }

    deletedName = GetGameObjectName(data->id);

    GameObject* object = ChatHandler(player->GetSession()).GetObjectFromPlayerMapByDbGuid(guid);
    if (!object)
    {
        SendAddonPayload(player, "DELETE_FAIL:GAMEOBJECT_NOT_LOADED_OR_NOT_ON_PLAYER_MAP:" + std::to_string(guid));
        return false;
    }

    if (ObjectGuid ownerGuid = object->GetOwnerGUID())
    {
        Unit* owner = ObjectAccessor::GetUnit(*object, ownerGuid);
        if (owner && ownerGuid.IsPlayer())
            owner->RemoveGameObject(object, false);
    }

    object->DeleteFromDB();
    object->SetRespawnTime(0);
    object->Delete();
    return true;
}



static bool SpawnPlacedCreature(Player* player, uint32 entry, uint32& outGuid, std::string& outName)
{
    outGuid = 0;
    outName.clear();

    if (!player || !entry)
        return false;

    if (!sObjectMgr->GetCreatureTemplate(entry))
    {
        SendAddonPayload(player, "PLACE_CREATURE_FAIL:CREATURE_TEMPLATE_NOT_FOUND:" + std::to_string(entry));
        return false;
    }

    Map* map = player->GetMap();
    if (!map)
    {
        SendAddonPayload(player, "PLACE_CREATURE_FAIL:MAP_NOT_AVAILABLE");
        return false;
    }

    // NPC placement mirrors AzerothCore .npc add behavior: spawn at the player's current position and facing.
    float const orientation = player->GetOrientation();
    float const x = player->GetPositionX();
    float const y = player->GetPositionY();
    float const z = player->GetPositionZ();
    uint32 const phaseMask = player->GetPhaseMaskForSpawn();

    if (!MapMgr::IsValidMapCoord(player->GetMapId(), x, y, z))
    {
        SendAddonPayload(player, "PLACE_CREATURE_FAIL:INVALID_MAP_COORDINATES");
        return false;
    }

    Creature* creature = new Creature();
    if (!creature->Create(map->GenerateLowGuid<HighGuid::Unit>(), map, phaseMask, entry, 0, x, y, z, orientation))
    {
        delete creature;
        SendAddonPayload(player, "PLACE_CREATURE_FAIL:CREATURE_CREATE_FAILED");
        return false;
    }

    creature->SaveToDB(map->GetId(), (1 << map->GetSpawnMode()), phaseMask);
    ObjectGuid::LowType spawnId = creature->GetSpawnId();

    creature->CleanupsBeforeDelete();
    delete creature;

    creature = new Creature();
    if (!creature->LoadCreatureFromDB(spawnId, map, true, true))
    {
        delete creature;
        SendAddonPayload(player, "PLACE_CREATURE_FAIL:CREATURE_LOAD_FROM_DB_FAILED:" + std::to_string(uint32(spawnId)));
        return false;
    }

    sObjectMgr->AddCreatureToGrid(spawnId, sObjectMgr->GetCreatureData(spawnId));

    outGuid = uint32(spawnId);
    outName = GetCreatureName(entry);
    LastPlacedCreatureGuidByPlayer[player->GetGUID().GetRawValue()] = outGuid;
    return true;
}

static bool DeleteCreatureByDbGuid(Player* player, uint32 guid, std::string& deletedName)
{
    if (!player || !guid)
        return false;

    CreatureData const* data = sObjectMgr->GetCreatureData(guid);
    if (!data)
    {
        SendAddonPayload(player, "DELETE_CREATURE_FAIL:CREATURE_DATA_NOT_FOUND:" + std::to_string(guid));
        return false;
    }

    deletedName = GetCreatureName(data->id1);

    Creature* creature = ChatHandler(player->GetSession()).GetCreatureFromPlayerMapByDbGuid(guid);
    if (!creature || creature->IsPet() || creature->IsTotem())
    {
        SendAddonPayload(player, "DELETE_CREATURE_FAIL:CREATURE_NOT_LOADED_OR_NOT_ON_PLAYER_MAP:" + std::to_string(guid));
        return false;
    }

    creature->CombatStop();
    creature->DeleteFromDB();
    creature->AddObjectToRemoveList();
    return true;
}


static bool IsCreatureGuidAllowedForPlayer(Player* player, uint32 guid)
{
    if (!player || !guid)
        return false;

    uint64 const playerGuid = player->GetGUID().GetRawValue();

    auto scanItr = LastScanCreatureGuidsByPlayer.find(playerGuid);
    if (scanItr != LastScanCreatureGuidsByPlayer.end() && scanItr->second.find(guid) != scanItr->second.end())
        return true;

    auto placedItr = LastPlacedCreatureGuidByPlayer.find(playerGuid);
    return placedItr != LastPlacedCreatureGuidByPlayer.end() && placedItr->second == guid;
}

static bool LoadEditableCreature(Player* player, uint32 guid, Creature*& creature, CreatureData const*& data, char const* failPrefix)
{
    creature = nullptr;
    data = nullptr;

    if (!player || !guid)
        return false;

    if (!IsCreatureGuidAllowedForPlayer(player, guid))
    {
        SendAddonPayload(player, std::string(failPrefix) + ":GUID_NOT_IN_LAST_SCAN_OR_LAST_PLACED_NPC:" + std::to_string(guid));
        return false;
    }

    data = sObjectMgr->GetCreatureData(guid);
    if (!data)
    {
        SendAddonPayload(player, std::string(failPrefix) + ":CREATURE_DATA_NOT_FOUND:" + std::to_string(guid));
        return false;
    }

    creature = ChatHandler(player->GetSession()).GetCreatureFromPlayerMapByDbGuid(guid);
    if (!creature || creature->IsPet() || creature->IsTotem())
    {
        SendAddonPayload(player, std::string(failPrefix) + ":CREATURE_NOT_LOADED_OR_NOT_ON_PLAYER_MAP:" + std::to_string(guid));
        return false;
    }

    return true;
}


static CreatureTransform MakeCreatureTransform(CreatureData const* data)
{
    CreatureTransform transform;
    if (!data)
        return transform;

    transform.x = data->posX;
    transform.y = data->posY;
    transform.z = data->posZ;
    transform.o = data->orientation;
    return transform;
}

static CreatureEditState& GetCreatureEditState(Player* player, uint32 guid, CreatureData const* data)
{
    uint64 const playerGuid = player->GetGUID().GetRawValue();
    CreatureEditState& state = CreatureEditStateByPlayer[playerGuid][guid];
    if (!state.hasOriginal)
    {
        state.original = MakeCreatureTransform(data);
        state.saved = state.original;
        state.hasOriginal = true;
        state.hasSaved = false;
        state.undoHistory.clear();
    }

    return state;
}

static void SendCreatureUndoRestoreStatus(Player* player, uint32 guid, CreatureEditState const& state)
{
    if (!player)
        return;

    if (state.undoHistory.empty())
        SendAddonPayload(player, "CREATURE_UNDO_STATUS:ORIGINAL:" + std::to_string(guid) + ":0");
    else
        SendAddonPayload(player, "CREATURE_UNDO_STATUS:AVAILABLE:" + std::to_string(guid) + ":" + std::to_string(state.undoHistory.size()));

    if (state.hasSaved)
        SendAddonPayload(player, "CREATURE_RESTORE:AVAILABLE:" + std::to_string(guid));
    else
        SendAddonPayload(player, "CREATURE_RESTORE:UNAVAILABLE:" + std::to_string(guid));
}

static bool ParseCreatureGuidFromParts(Player* player, std::vector<std::string> const& parts, char const* failPrefix, uint32& guid)
{
    guid = 0;
    if (parts.size() < 2)
    {
        SendAddonPayload(player, std::string(failPrefix) + ":MISSING_GUID");
        return false;
    }

    std::string guidText = Trim(parts[1]);
    if (guidText.empty() || guidText.find_first_not_of("0123456789") != std::string::npos)
    {
        SendAddonPayload(player, std::string(failPrefix) + ":BAD_GUID");
        return false;
    }

    uint64 guidValue = 0;
    for (char c : guidText)
    {
        guidValue = (guidValue * 10) + uint64(c - '0');
        if (guidValue > std::numeric_limits<uint32>::max())
        {
            SendAddonPayload(player, std::string(failPrefix) + ":GUID_OUT_OF_RANGE");
            return false;
        }
    }

    guid = uint32(guidValue);
    return true;
}

static void ApplyCreaturePosition(Creature* creature, CreatureData const* data, uint32 guid, float x, float y, float z, float o)
{
    // Mirror AzerothCore's .npc move persistence/refresh path, but use the
    // calculated editor coordinates instead of the player's current position.
    // Direct SQL formatting was not reliable enough here; the prepared
    // statement keeps this on the same path as cs_npc.cpp.
    if (data)
    {
        CreatureData* mutableData = const_cast<CreatureData*>(data);
        mutableData->posX = x;
        mutableData->posY = y;
        mutableData->posZ = z;
        mutableData->orientation = o;
    }

    if (creature)
    {
        creature->SetPosition(x, y, z, o);
        creature->GetMotionMaster()->Initialize();

        if (creature->IsAlive())
        {
            creature->setDeathState(DeathState::JustDied);
            creature->Respawn();
        }
    }

    WorldDatabasePreparedStatement* stmt = WorldDatabase.GetPreparedStatement(WORLD_UPD_CREATURE_POSITION);
    stmt->SetData(0, x);
    stmt->SetData(1, y);
    stmt->SetData(2, z);
    stmt->SetData(3, o);
    stmt->SetData(4, guid);
    WorldDatabase.Execute(stmt);
}

static void SendCreatureUpdated(Player* player, uint32 guid)
{
    if (!player)
        return;

    ScanCandidate row;
    if (!GetCreatureData(guid, row))
    {
        SendAddonPayload(player, "NUDGE_CREATURE_FAIL:CREATURE_DATA_NOT_FOUND_AFTER_UPDATE:" + std::to_string(guid));
        return;
    }

    row.distance = player->GetDistance2d(row.transform.x, row.transform.y);
    SendAddonPayload(player, BuildObjectPayload("NPC_UPDATED", row));
}

static void HandleNudgeCreature(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 4)
    {
        SendAddonPayload(player, "NUDGE_CREATURE_FAIL:BAD_ARGS");
        return;
    }

    std::string guidText = Trim(parts[1]);
    if (guidText.empty() || guidText.find_first_not_of("0123456789") != std::string::npos)
    {
        SendAddonPayload(player, "NUDGE_CREATURE_FAIL:BAD_GUID");
        return;
    }

    uint64 guidValue = 0;
    for (char c : guidText)
    {
        guidValue = (guidValue * 10) + uint64(c - '0');
        if (guidValue > std::numeric_limits<uint32>::max())
        {
            SendAddonPayload(player, "NUDGE_CREATURE_FAIL:GUID_OUT_OF_RANGE");
            return;
        }
    }

    uint32 const guid = uint32(guidValue);
    std::string dir = parts[2];

    float step = 0.0f;
    try
    {
        step = std::stof(parts[3]);
    }
    catch (...)
    {
        SendAddonPayload(player, "NUDGE_CREATURE_FAIL:BAD_STEP");
        return;
    }

    step = std::max(0.0f, std::min(step, MaxNudgeDistance()));

    Creature* creature = nullptr;
    CreatureData const* data = nullptr;
    if (!LoadEditableCreature(player, guid, creature, data, "NUDGE_CREATURE_FAIL"))
        return;

    CreatureEditState& editState = GetCreatureEditState(player, guid, data);
    editState.undoHistory.push_back(MakeCreatureTransform(data));

    float x = data->posX;
    float y = data->posY;
    float z = data->posZ;
    float o = data->orientation;

    std::string moveMode = parts.size() >= 5 ? Trim(parts[4]) : "PLAYER";
    float const moveOrientation = (moveMode == "OBJECT") ? o : player->GetOrientation();
    float const forwardX = std::cos(moveOrientation);
    float const forwardY = std::sin(moveOrientation);
    float const leftX = std::cos(moveOrientation + static_cast<float>(M_PI) * 0.5f);
    float const leftY = std::sin(moveOrientation + static_cast<float>(M_PI) * 0.5f);

    if (dir == "FORWARD")
    {
        x += forwardX * step;
        y += forwardY * step;
    }
    else if (dir == "BACK")
    {
        x -= forwardX * step;
        y -= forwardY * step;
    }
    else if (dir == "LEFT")
    {
        x += leftX * step;
        y += leftY * step;
    }
    else if (dir == "RIGHT")
    {
        x -= leftX * step;
        y -= leftY * step;
    }
    else if (dir == "UP")
        z += step;
    else if (dir == "DOWN")
        z -= step;
    else
    {
        SendAddonPayload(player, "NUDGE_CREATURE_FAIL:UNKNOWN_DIRECTION");
        return;
    }

    if (!MapMgr::IsValidMapCoord(data->mapid, x, y, z))
    {
        SendAddonPayload(player, "NUDGE_CREATURE_FAIL:INVALID_MAP_COORDINATES");
        return;
    }

    ApplyCreaturePosition(creature, data, guid, x, y, z, o);
    SendCreatureUpdated(player, guid);
    SendCreatureUndoRestoreStatus(player, guid, editState);
}

static void HandleRotateCreature(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 4)
    {
        SendAddonPayload(player, "ROTATE_CREATURE_FAIL:BAD_ARGS");
        return;
    }

    std::string guidText = Trim(parts[1]);
    if (guidText.empty() || guidText.find_first_not_of("0123456789") != std::string::npos)
    {
        SendAddonPayload(player, "ROTATE_CREATURE_FAIL:BAD_GUID");
        return;
    }

    uint64 guidValue = 0;
    for (char c : guidText)
    {
        guidValue = (guidValue * 10) + uint64(c - '0');
        if (guidValue > std::numeric_limits<uint32>::max())
        {
            SendAddonPayload(player, "ROTATE_CREATURE_FAIL:GUID_OUT_OF_RANGE");
            return;
        }
    }

    uint32 const guid = uint32(guidValue);
    std::string axis = parts[2];

    float deltaDegrees = 0.0f;
    try
    {
        deltaDegrees = std::stof(parts[3]);
    }
    catch (...)
    {
        SendAddonPayload(player, "ROTATE_CREATURE_FAIL:BAD_STEP");
        return;
    }

    deltaDegrees = std::max(-MaxNudgeDistance(), std::min(deltaDegrees, MaxNudgeDistance()));

    if (axis != "YAW")
    {
        SendAddonPayload(player, "ROTATE_CREATURE_UNSUPPORTED:" + axis);
        return;
    }

    Creature* creature = nullptr;
    CreatureData const* data = nullptr;
    if (!LoadEditableCreature(player, guid, creature, data, "ROTATE_CREATURE_FAIL"))
        return;

    float const x = data->posX;
    float const y = data->posY;
    float const z = data->posZ;
    float const o = NormalizeAngle(data->orientation + deltaDegrees * static_cast<float>(M_PI) / 180.0f);

    ApplyCreaturePosition(creature, data, guid, x, y, z, o);
    SendCreatureUpdated(player, guid);
}


static void HandleUndoCreature(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    uint32 guid = 0;
    if (!ParseCreatureGuidFromParts(player, parts, "UNDO_CREATURE_FAIL", guid))
        return;

    Creature* creature = nullptr;
    CreatureData const* data = nullptr;
    if (!LoadEditableCreature(player, guid, creature, data, "UNDO_CREATURE_FAIL"))
        return;

    CreatureEditState& editState = GetCreatureEditState(player, guid, data);
    if (editState.undoHistory.empty())
    {
        SendAddonPayload(player, "UNDO_CREATURE_FAIL:NO_UNDO_AVAILABLE:" + std::to_string(guid));
        SendCreatureUndoRestoreStatus(player, guid, editState);
        return;
    }

    CreatureTransform transform = editState.undoHistory.back();
    editState.undoHistory.pop_back();
    ApplyCreaturePosition(creature, data, guid, transform.x, transform.y, transform.z, transform.o);
    SendCreatureUpdated(player, guid);
    SendCreatureUndoRestoreStatus(player, guid, editState);
    SendAddonPayload(player, "CREATURE_UNDONE:" + std::to_string(guid));
}

static void HandleSaveCreature(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    uint32 guid = 0;
    if (!ParseCreatureGuidFromParts(player, parts, "SAVE_CREATURE_FAIL", guid))
        return;

    Creature* creature = nullptr;
    CreatureData const* data = nullptr;
    if (!LoadEditableCreature(player, guid, creature, data, "SAVE_CREATURE_FAIL"))
        return;

    CreatureEditState& editState = GetCreatureEditState(player, guid, data);
    editState.saved = MakeCreatureTransform(data);
    editState.hasSaved = true;
    SendCreatureUndoRestoreStatus(player, guid, editState);
    SendAddonPayload(player, "CREATURE_SAVED:" + std::to_string(guid));
}

static void HandleRestoreCreaturePosition(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    uint32 guid = 0;
    if (!ParseCreatureGuidFromParts(player, parts, "RESTORE_CREATURE_FAIL", guid))
        return;

    Creature* creature = nullptr;
    CreatureData const* data = nullptr;
    if (!LoadEditableCreature(player, guid, creature, data, "RESTORE_CREATURE_FAIL"))
        return;

    CreatureEditState& editState = GetCreatureEditState(player, guid, data);
    if (!editState.hasSaved)
    {
        SendAddonPayload(player, "RESTORE_CREATURE_FAIL:NO_SAVED_POSITION:" + std::to_string(guid));
        SendCreatureUndoRestoreStatus(player, guid, editState);
        return;
    }

    editState.undoHistory.push_back(MakeCreatureTransform(data));
    ApplyCreaturePosition(creature, data, guid, editState.saved.x, editState.saved.y, editState.saved.z, editState.saved.o);
    SendCreatureUpdated(player, guid);
    SendCreatureUndoRestoreStatus(player, guid, editState);
    SendAddonPayload(player, "CREATURE_RESTORED:" + std::to_string(guid));
}

static void HandleResetCreatureToOriginal(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    uint32 guid = 0;
    if (!ParseCreatureGuidFromParts(player, parts, "RESET_CREATURE_FAIL", guid))
        return;

    Creature* creature = nullptr;
    CreatureData const* data = nullptr;
    if (!LoadEditableCreature(player, guid, creature, data, "RESET_CREATURE_FAIL"))
        return;

    CreatureEditState& editState = GetCreatureEditState(player, guid, data);
    if (!editState.hasOriginal)
    {
        SendAddonPayload(player, "RESET_CREATURE_FAIL:NO_ORIGINAL_POSITION:" + std::to_string(guid));
        SendCreatureUndoRestoreStatus(player, guid, editState);
        return;
    }

    editState.undoHistory.push_back(MakeCreatureTransform(data));
    ApplyCreaturePosition(creature, data, guid, editState.original.x, editState.original.y, editState.original.z, editState.original.o);
    editState.undoHistory.clear();
    SendCreatureUpdated(player, guid);
    SendCreatureUndoRestoreStatus(player, guid, editState);
    SendAddonPayload(player, "CREATURE_RESET_ORIGINAL:" + std::to_string(guid));
}

static void ClearEditorSession(Player* player)
{
    if (!player)
        return;

    uint64 guid = player->GetGUID().GetRawValue();
    auto itr = SelectedByPlayer.find(guid);
    if (itr != SelectedByPlayer.end())
        DespawnSelectionPreview(player, itr->second);

    SelectedByPlayer.erase(guid);
    LastScanGuidsByPlayer.erase(guid);
    LastScanCreatureGuidsByPlayer.erase(guid);
    LastPlacedCreatureGuidByPlayer.erase(guid);
    CreatureEditStateByPlayer.erase(guid);
    SendAddonPayload(player, "CLEARED");
}

static void HandleHello(Player* player)
{
    if (HasAccess(player))
        SendAddonPayload(player, GE_ACCESS_VERIFIED);
    else
        SendAddonPayload(player, GE_ACCESS_DENIED);
}

static void HandleScan(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    float distance = 5.0f;
    if (parts.size() >= 2)
        distance = std::stof(parts[1]);

    std::vector<ScanCandidate> rows = BuildScan(player, distance);

    uint64 playerGuid = player->GetGUID().GetRawValue();
    LastScanGuidsByPlayer[playerGuid].clear();
    LastScanCreatureGuidsByPlayer[playerGuid].clear();

    SendAddonPayload(player, "SCAN_BEGIN:" + std::to_string(rows.size()));
    for (ScanCandidate const& row : rows)
    {
        if (row.isCreature)
        {
            LastScanCreatureGuidsByPlayer[playerGuid].insert(row.guid);
            SendAddonPayload(player, BuildObjectPayload("NPC", row));
        }
        else
        {
            LastScanGuidsByPlayer[playerGuid].insert(row.guid);
            SendAddonPayload(player, BuildObjectPayload("OBJ", row));
        }
    }
    SendAddonPayload(player, "SCAN_END");
}

static void HandleSearchTemplate(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 2)
    {
        SendAddonPayload(player, "GOBJECT_SEARCH_BEGIN:0");
        SendAddonPayload(player, "GOBJECT_SEARCH_END");
        SendAddonPayload(player, "ERROR:SEARCH_TEXT_REQUIRED");
        return;
    }

    std::string searchText = Trim(parts[1]);
    for (size_t i = 2; i < parts.size(); ++i)
        searchText += ":" + parts[i];
    searchText = Trim(searchText);

    if (searchText.empty())
    {
        SendAddonPayload(player, "GOBJECT_SEARCH_BEGIN:0");
        SendAddonPayload(player, "GOBJECT_SEARCH_END");
        SendAddonPayload(player, "ERROR:SEARCH_TEXT_REQUIRED");
        return;
    }

    bool const isNumericSearch = searchText.find_first_not_of("0123456789") == std::string::npos;

    QueryResult result;
    if (isNumericSearch)
    {
        uint64 entryValue = 0;
        bool entryInRange = true;
        for (char c : searchText)
        {
            entryValue = (entryValue * 10) + uint64(c - '0');
            if (entryValue > std::numeric_limits<uint32>::max())
            {
                entryInRange = false;
                break;
            }
        }

        if (entryInRange)
        {
            result = WorldDatabase.Query(
                "SELECT `entry`, `type`, `displayId`, `name` "
                "FROM `gameobject_template` "
                "WHERE `entry` = {} "
                "LIMIT 1",
                uint32(entryValue));
        }
    }
    else
    {
        if (searchText.length() < 2)
        {
            SendAddonPayload(player, "GOBJECT_SEARCH_BEGIN:0");
            SendAddonPayload(player, "GOBJECT_SEARCH_END");
            SendAddonPayload(player, "ERROR:SEARCH_TEXT_TOO_SHORT");
            return;
        }

        std::string escapedSearch = searchText;
        WorldDatabase.EscapeString(escapedSearch);

        result = WorldDatabase.Query(
            "SELECT `entry`, `type`, `displayId`, `name` "
            "FROM `gameobject_template` "
            "WHERE `name` LIKE '%{}%' "
            "ORDER BY "
            "CASE "
            "WHEN `name` = '{}' THEN 0 "
            "WHEN `name` LIKE '{}%' THEN 1 "
            "ELSE 2 END, `name` ASC, `entry` ASC "
            "LIMIT 300",
            escapedSearch.c_str(), escapedSearch.c_str(), escapedSearch.c_str());
    }

    std::vector<TemplateSearchRow> rows;
    if (result)
    {
        do
        {
            Field* fields = result->Fetch();
            TemplateSearchRow row;
            row.entry = fields[0].Get<uint32>();
            row.type = fields[1].Get<uint32>();
            row.displayId = fields[2].Get<uint32>();
            row.modelPath = GetGameObjectModelPath(row.displayId);
            row.name = fields[3].Get<std::string>();
            rows.push_back(row);
        } while (result->NextRow());
    }

    SendAddonPayload(player, "GOBJECT_SEARCH_BEGIN:" + std::to_string(rows.size()));
    for (TemplateSearchRow const& row : rows)
        SendAddonPayload(player, BuildTemplateSearchPayload(row));
    SendAddonPayload(player, "GOBJECT_SEARCH_END");
}


static void HandleSearchCreatureTemplate(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 2)
    {
        SendAddonPayload(player, "CREATURE_SEARCH_BEGIN:0");
        SendAddonPayload(player, "CREATURE_SEARCH_END");
        SendAddonPayload(player, "ERROR:SEARCH_TEXT_REQUIRED");
        return;
    }

    std::string searchText = Trim(parts[1]);
    for (size_t i = 2; i < parts.size(); ++i)
        searchText += ":" + parts[i];
    searchText = Trim(searchText);

    if (searchText.empty())
    {
        SendAddonPayload(player, "CREATURE_SEARCH_BEGIN:0");
        SendAddonPayload(player, "CREATURE_SEARCH_END");
        SendAddonPayload(player, "ERROR:SEARCH_TEXT_REQUIRED");
        return;
    }

    bool const isNumericSearch = searchText.find_first_not_of("0123456789") == std::string::npos;

    QueryResult result;
    if (isNumericSearch)
    {
        uint64 entryValue = 0;
        bool entryInRange = true;
        for (char c : searchText)
        {
            entryValue = (entryValue * 10) + uint64(c - '0');
            if (entryValue > std::numeric_limits<uint32>::max())
            {
                entryInRange = false;
                break;
            }
        }

        if (entryInRange)
        {
            result = WorldDatabase.Query(
                "SELECT c.`entry`, c.`type`, "
                "COALESCE(GROUP_CONCAT(ctm.`CreatureDisplayID` ORDER BY ctm.`Idx` ASC SEPARATOR ','), '') AS `displayIds`, "
                "c.`name` "
                "FROM `creature_template` c "
                "LEFT JOIN `creature_template_model` ctm ON ctm.`CreatureID` = c.`entry` "
                "WHERE c.`entry` = {} "
                "GROUP BY c.`entry`, c.`type`, c.`name` "
                "LIMIT 1",
                uint32(entryValue));
        }
    }
    else
    {
        if (searchText.length() < 2)
        {
            SendAddonPayload(player, "CREATURE_SEARCH_BEGIN:0");
            SendAddonPayload(player, "CREATURE_SEARCH_END");
            SendAddonPayload(player, "ERROR:SEARCH_TEXT_TOO_SHORT");
            return;
        }

        std::string escapedSearch = searchText;
        WorldDatabase.EscapeString(escapedSearch);

        result = WorldDatabase.Query(
            "SELECT c.`entry`, c.`type`, "
            "COALESCE(GROUP_CONCAT(ctm.`CreatureDisplayID` ORDER BY ctm.`Idx` ASC SEPARATOR ','), '') AS `displayIds`, "
            "c.`name` "
            "FROM `creature_template` c "
            "LEFT JOIN `creature_template_model` ctm ON ctm.`CreatureID` = c.`entry` "
            "WHERE c.`name` LIKE '%{}%' "
            "GROUP BY c.`entry`, c.`type`, c.`name` "
            "ORDER BY "
            "CASE "
            "WHEN c.`name` = '{}' THEN 0 "
            "WHEN c.`name` LIKE '{}%' THEN 1 "
            "ELSE 2 END, c.`name` ASC, c.`entry` ASC "
            "LIMIT 300",
            escapedSearch.c_str(), escapedSearch.c_str(), escapedSearch.c_str());
    }

    std::vector<CreatureTemplateSearchRow> rows;
    if (result)
    {
        do
        {
            Field* fields = result->Fetch();
            CreatureTemplateSearchRow row;
            row.entry = fields[0].Get<uint32>();
            row.type = fields[1].Get<uint32>();
            row.displayIds = fields[2].Get<std::string>();
            row.displayId = GetFirstDisplayIdFromList(row.displayIds);
            row.name = fields[3].Get<std::string>();
            rows.push_back(row);
        } while (result->NextRow());
    }

    SendAddonPayload(player, "CREATURE_SEARCH_BEGIN:" + std::to_string(rows.size()));
    for (CreatureTemplateSearchRow const& row : rows)
        SendAddonPayload(player, BuildCreatureTemplateSearchPayload(row));
    SendAddonPayload(player, "CREATURE_SEARCH_END");
}


static void HandlePlaceTemplate(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 2)
    {
        SendAddonPayload(player, "PLACE_FAIL:MISSING_ENTRY");
        return;
    }

    std::string entryText = Trim(parts[1]);
    if (entryText.empty() || entryText.find_first_not_of("0123456789") != std::string::npos)
    {
        SendAddonPayload(player, "PLACE_FAIL:BAD_ENTRY");
        return;
    }

    uint64 entryValue = 0;
    for (char c : entryText)
    {
        entryValue = (entryValue * 10) + uint64(c - '0');
        if (entryValue > std::numeric_limits<uint32>::max())
        {
            SendAddonPayload(player, "PLACE_FAIL:ENTRY_OUT_OF_RANGE");
            return;
        }
    }

    ScanCandidate candidate;
    if (!SpawnPlacedGameObject(player, uint32(entryValue), candidate))
        return;

    uint64 playerGuid = player->GetGUID().GetRawValue();
    if (SelectedByPlayer[playerGuid].hasSelection)
        DespawnSelectionPreview(player, SelectedByPlayer[playerGuid]);

    SelectedByPlayer[playerGuid] = ToSelectedObject(candidate);
    LastScanGuidsByPlayer[playerGuid].insert(candidate.guid);

    SendAddonPayload(player, BuildSelectedPayload("SELECTED", SelectedByPlayer[playerGuid]));
    SendAddonPayload(player, "RESTORE:UNAVAILABLE");
    SendUndoStatus(player, SelectedByPlayer[playerGuid]);
    SendAddonPayload(player, "PLACE_OK:" + std::to_string(candidate.guid) + ":" + std::to_string(candidate.entry) + ":" + EscapePayloadString(candidate.name));
}



static void HandlePlaceCreatureTemplate(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 2)
    {
        SendAddonPayload(player, "PLACE_CREATURE_FAIL:MISSING_ENTRY");
        return;
    }

    std::string entryText = Trim(parts[1]);
    if (entryText.empty() || entryText.find_first_not_of("0123456789") != std::string::npos)
    {
        SendAddonPayload(player, "PLACE_CREATURE_FAIL:BAD_ENTRY");
        return;
    }

    uint64 entryValue = 0;
    for (char c : entryText)
    {
        entryValue = (entryValue * 10) + uint64(c - '0');
        if (entryValue > std::numeric_limits<uint32>::max())
        {
            SendAddonPayload(player, "PLACE_CREATURE_FAIL:ENTRY_OUT_OF_RANGE");
            return;
        }
    }

    uint32 guid = 0;
    std::string name;
    if (!SpawnPlacedCreature(player, uint32(entryValue), guid, name))
        return;

    SendAddonPayload(player, "PLACE_CREATURE_OK:" + std::to_string(guid) + ":" + std::to_string(uint32(entryValue)) + ":" + EscapePayloadString(name));
}

static void HandleDeleteCreatureSelected(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 2)
    {
        SendAddonPayload(player, "DELETE_CREATURE_FAIL:MISSING_GUID");
        return;
    }

    std::string guidText = Trim(parts[1]);
    if (guidText.empty() || guidText.find_first_not_of("0123456789") != std::string::npos)
    {
        SendAddonPayload(player, "DELETE_CREATURE_FAIL:BAD_GUID");
        return;
    }

    uint64 guidValue = 0;
    for (char c : guidText)
    {
        guidValue = (guidValue * 10) + uint64(c - '0');
        if (guidValue > std::numeric_limits<uint32>::max())
        {
            SendAddonPayload(player, "DELETE_CREATURE_FAIL:GUID_OUT_OF_RANGE");
            return;
        }
    }

    uint32 const guid = uint32(guidValue);
    uint64 const playerGuid = player->GetGUID().GetRawValue();

    bool allowed = false;
    auto placedItr = LastPlacedCreatureGuidByPlayer.find(playerGuid);
    if (placedItr != LastPlacedCreatureGuidByPlayer.end() && placedItr->second == guid)
        allowed = true;

    auto scanItr = LastScanCreatureGuidsByPlayer.find(playerGuid);
    if (scanItr != LastScanCreatureGuidsByPlayer.end() && scanItr->second.count(guid) != 0)
        allowed = true;

    if (!allowed)
    {
        SendAddonPayload(player, "DELETE_CREATURE_FAIL:GUID_NOT_IN_LAST_SCAN_OR_LAST_PLACED_NPC");
        return;
    }

    std::string deletedName;
    if (!DeleteCreatureByDbGuid(player, guid, deletedName))
        return;

    if (placedItr != LastPlacedCreatureGuidByPlayer.end() && placedItr->second == guid)
        LastPlacedCreatureGuidByPlayer.erase(playerGuid);

    if (scanItr != LastScanCreatureGuidsByPlayer.end())
        scanItr->second.erase(guid);

    auto editItr = CreatureEditStateByPlayer.find(playerGuid);
    if (editItr != CreatureEditStateByPlayer.end())
        editItr->second.erase(guid);

    SendAddonPayload(player, "DELETE_CREATURE_OK:" + std::to_string(guid) + ":" + EscapePayloadString(deletedName));
}

static void HandlePreviewCreatureCache(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 2)
    {
        SendAddonPayload(player, "PREVIEW_CREATURE_CACHE_FAIL:MISSING_ENTRY");
        return;
    }

    std::string entryText = Trim(parts[1]);
    if (entryText.empty() || entryText.find_first_not_of("0123456789") != std::string::npos)
    {
        SendAddonPayload(player, "PREVIEW_CREATURE_CACHE_FAIL:BAD_ENTRY");
        return;
    }

    uint64 entryValue = 0;
    for (char c : entryText)
    {
        entryValue = (entryValue * 10) + uint64(c - '0');
        if (entryValue > std::numeric_limits<uint32>::max())
        {
            SendAddonPayload(player, "PREVIEW_CREATURE_CACHE_FAIL:ENTRY_OUT_OF_RANGE");
            return;
        }
    }

    uint32 const entry = uint32(entryValue);
    CreatureTemplate const* creatureTemplate = sObjectMgr->GetCreatureTemplate(entry);
    if (!creatureTemplate)
    {
        SendAddonPayload(player, "PREVIEW_CREATURE_CACHE_FAIL:CREATURE_TEMPLATE_NOT_FOUND:" + std::to_string(entry));
        return;
    }

    float const x = player->GetPositionX();
    float const y = player->GetPositionY();
    float const z = player->GetPositionZ() - 40.0f;
    float const o = player->GetOrientation();

    auto* preview = player->SummonCreature(entry, x, y, z, o, TEMPSUMMON_TIMED_DESPAWN, 750);
    Creature* previewCreature = preview ? preview->ToCreature() : nullptr;
    if (!previewCreature)
    {
        SendAddonPayload(player, "PREVIEW_CREATURE_CACHE_FAIL:SUMMON_FAILED:" + std::to_string(entry));
        return;
    }

    previewCreature->SetFaction(player->GetFaction());
    previewCreature->SetReactState(REACT_PASSIVE);
    previewCreature->CombatStop(true);
    previewCreature->SetTarget(ObjectGuid::Empty);
    previewCreature->SetVisible(false);
    previewCreature->SetObjectScale(0.001f);
    previewCreature->SetFlag(UNIT_FIELD_FLAGS, UNIT_FLAG_NON_ATTACKABLE | UNIT_FLAG_NOT_SELECTABLE);
    previewCreature->GetMotionMaster()->Clear();
    previewCreature->GetMotionMaster()->MoveIdle();
    previewCreature->DespawnOrUnsummon(Milliseconds(750));

    SendAddonPayload(player, "PREVIEW_CREATURE_CACHE_OK:" + std::to_string(entry));
}

static void HandleDeleteSelected(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 2)
    {
        SendAddonPayload(player, "DELETE_FAIL:MISSING_GUID");
        return;
    }

    std::string guidText = Trim(parts[1]);
    if (guidText.empty() || guidText.find_first_not_of("0123456789") != std::string::npos)
    {
        SendAddonPayload(player, "DELETE_FAIL:BAD_GUID");
        return;
    }

    uint64 guidValue = 0;
    for (char c : guidText)
    {
        guidValue = (guidValue * 10) + uint64(c - '0');
        if (guidValue > std::numeric_limits<uint32>::max())
        {
            SendAddonPayload(player, "DELETE_FAIL:GUID_OUT_OF_RANGE");
            return;
        }
    }

    uint32 const guid = uint32(guidValue);
    uint64 const playerGuid = player->GetGUID().GetRawValue();

    auto selectedItr = SelectedByPlayer.find(playerGuid);
    if (selectedItr == SelectedByPlayer.end() || !selectedItr->second.hasSelection)
    {
        SendAddonPayload(player, "DELETE_FAIL:NO_SELECTED_OBJECT");
        return;
    }

    if (selectedItr->second.guid != guid)
    {
        SendAddonPayload(player, "DELETE_FAIL:GUID_DOES_NOT_MATCH_SELECTED_OBJECT");
        return;
    }

    DespawnSelectionPreview(player, selectedItr->second);

    std::string deletedName;
    if (!DeleteGameObjectByDbGuid(player, guid, deletedName))
        return;

    SelectedByPlayer.erase(playerGuid);
    LastScanGuidsByPlayer[playerGuid].erase(guid);

    SendAddonPayload(player, "DELETE_OK:" + std::to_string(guid) + ":" + EscapePayloadString(deletedName));
    SendUndoStatus(player, SelectedObject());
    SendAddonPayload(player, "RESTORE:UNAVAILABLE");
}


static void HandleSelect(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 2)
    {
        SendAddonPayload(player, "ERROR:SELECT_MISSING_GUID");
        return;
    }

    uint32 guid = static_cast<uint32>(std::stoul(parts[1]));
    uint64 playerGuid = player->GetGUID().GetRawValue();

    if (!LastScanGuidsByPlayer[playerGuid].empty() && LastScanGuidsByPlayer[playerGuid].count(guid) == 0)
    {
        SendAddonPayload(player, "ERROR:GUID_NOT_IN_LAST_SCAN");
        return;
    }

    ScanCandidate candidate;
    if (!GetObjectData(guid, candidate))
    {
        SendAddonPayload(player, "ERROR:GAMEOBJECT_NOT_FOUND");
        return;
    }

    if (SelectedByPlayer[playerGuid].hasSelection)
        DespawnSelectionPreview(player, SelectedByPlayer[playerGuid]);

    SelectedByPlayer[playerGuid] = ToSelectedObject(candidate);
    SendAddonPayload(player, BuildSelectedPayload("SELECTED", SelectedByPlayer[playerGuid]));
    SendAddonPayload(player, "RESTORE:UNAVAILABLE");
    SendUndoStatus(player, SelectedByPlayer[playerGuid]);
    SpawnSelectionPreview(player, SelectedByPlayer[playerGuid]);
}

static bool RequireSelection(Player* player, SelectedObject*& selected)
{
    if (!player)
        return false;

    auto itr = SelectedByPlayer.find(player->GetGUID().GetRawValue());
    if (itr == SelectedByPlayer.end() || !itr->second.hasSelection)
    {
        SendAddonPayload(player, "ERROR:NO_SELECTED_OBJECT");
        return false;
    }

    selected = &itr->second;
    return true;
}

static void SnapshotUndo(SelectedObject& selected)
{
    selected.previous = selected.current;
    selected.undoHistory.push_back(selected.current);
    selected.hasUndo = !selected.undoHistory.empty();
}

static void HandleNudge(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 3)
    {
        SendAddonPayload(player, "ERROR:NUDGE_BAD_ARGS");
        return;
    }

    SelectedObject* selected = nullptr;
    if (!RequireSelection(player, selected))
        return;

    std::string dir = parts[1];
    float step = std::stof(parts[2]);
    step = std::max(0.0f, std::min(step, MaxNudgeDistance()));

    SnapshotUndo(*selected);

    std::string moveMode = parts.size() >= 4 ? Trim(parts[3]) : "PLAYER";
    float const moveOrientation = (moveMode == "OBJECT") ? selected->current.o : player->GetOrientation();
    float const forwardX = std::cos(moveOrientation);
    float const forwardY = std::sin(moveOrientation);
    float const leftX = std::cos(moveOrientation + static_cast<float>(M_PI) * 0.5f);
    float const leftY = std::sin(moveOrientation + static_cast<float>(M_PI) * 0.5f);

    if (dir == "FORWARD")
    {
        selected->current.x += forwardX * step;
        selected->current.y += forwardY * step;
    }
    else if (dir == "BACK")
    {
        selected->current.x -= forwardX * step;
        selected->current.y -= forwardY * step;
    }
    else if (dir == "LEFT")
    {
        selected->current.x += leftX * step;
        selected->current.y += leftY * step;
    }
    else if (dir == "RIGHT")
    {
        selected->current.x -= leftX * step;
        selected->current.y -= leftY * step;
    }
    else if (dir == "UP")
        selected->current.z += step;
    else if (dir == "DOWN")
        selected->current.z -= step;
    else
    {
        SendAddonPayload(player, "ERROR:UNKNOWN_NUDGE_DIRECTION");
        return;
    }

    selected->dirty = true;
    SendAddonPayload(player, BuildSelectedPayload("UPDATED", *selected));
    SendUndoStatus(player, *selected);
    SpawnSelectionPreview(player, *selected);
}

static void HandleRotate(Player* player, std::vector<std::string> const& parts)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    if (parts.size() < 2)
    {
        SendAddonPayload(player, "ERROR:ROTATE_BAD_ARGS");
        return;
    }

    SelectedObject* selected = nullptr;
    if (!RequireSelection(player, selected))
        return;

    std::string axis = "YAW";
    float deltaDegrees = 0.0f;

    if (parts.size() >= 3)
    {
        axis = parts[1];
        deltaDegrees = std::stof(parts[2]);
    }
    else
        deltaDegrees = std::stof(parts[1]);

    deltaDegrees = std::max(-MaxNudgeDistance(), std::min(deltaDegrees, MaxNudgeDistance()));

    if (axis != "YAW" && axis != "PITCH" && axis != "ROLL")
    {
        SendAddonPayload(player, "ERROR:UNKNOWN_ROTATION_AXIS");
        return;
    }

    SnapshotUndo(*selected);
    ApplyAxisRotation(selected->current, axis, deltaDegrees);
    selected->dirty = true;
    SendAddonPayload(player, BuildSelectedPayload("UPDATED", *selected));
    SendUndoStatus(player, *selected);
    SpawnSelectionPreview(player, *selected);
}

static void HandleFaceMe(Player* player)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    SelectedObject* selected = nullptr;
    if (!RequireSelection(player, selected))
        return;

    SnapshotUndo(*selected);
    selected->current.o = player->GetOrientation();
    float const half = selected->current.o * 0.5f;
    selected->current.r0 = 0.0f;
    selected->current.r1 = 0.0f;
    selected->current.r2 = std::sin(half);
    selected->current.r3 = std::cos(half);
    selected->dirty = true;
    SendAddonPayload(player, BuildSelectedPayload("UPDATED", *selected));
    SendUndoStatus(player, *selected);
    SpawnSelectionPreview(player, *selected);
}

static void HandleUndo(Player* player)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    SelectedObject* selected = nullptr;
    if (!RequireSelection(player, selected))
        return;

    if (selected->undoHistory.empty())
    {
        SendAddonPayload(player, "ERROR:NO_UNDO_AVAILABLE");
        SendUndoStatus(player, *selected);
        return;
    }

    selected->current = selected->undoHistory.back();
    selected->undoHistory.pop_back();
    selected->hasUndo = !selected->undoHistory.empty();
    selected->dirty = true;
    SendAddonPayload(player, BuildSelectedPayload("UPDATED", *selected));
    SendUndoStatus(player, *selected);
    SpawnSelectionPreview(player, *selected);
}


static void HandleResetToOriginal(Player* player)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    SelectedObject* selected = nullptr;
    if (!RequireSelection(player, selected))
        return;

    if (selected->undoHistory.empty())
    {
        SendAddonPayload(player, "ERROR:NO_RESET_AVAILABLE");
        SendUndoStatus(player, *selected);
        return;
    }

    selected->current = selected->undoHistory.front();
    selected->undoHistory.clear();
    selected->hasUndo = false;
    selected->dirty = true;

    SendAddonPayload(player, BuildSelectedPayload("UPDATED", *selected));
    SendUndoStatus(player, *selected);
    SendAddonPayload(player, "RESET_ORIGINAL:" + std::to_string(selected->guid));
    SpawnSelectionPreview(player, *selected);
}

static void HandleSave(Player* player)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    SelectedObject* selected = nullptr;
    if (!RequireSelection(player, selected))
        return;

    selected->restorePosition = selected->lastSaved;
    selected->hasRestore = true;

    WorldDatabase.Execute(
        "UPDATE `gameobject` SET `position_x` = {}, `position_y` = {}, `position_z` = {}, `orientation` = {}, `rotation0` = {}, `rotation1` = {}, `rotation2` = {}, `rotation3` = {} WHERE `guid` = {}",
        selected->current.x, selected->current.y, selected->current.z, selected->current.o,
        selected->current.r0, selected->current.r1, selected->current.r2, selected->current.r3, selected->guid);

    selected->lastSaved = selected->current;
    selected->dirty = false;
    selected->undoHistory.clear();
    selected->hasUndo = false;

    SendAddonPayload(player, "SAVED:" + std::to_string(selected->guid));
    SendUndoStatus(player, *selected);
    SendAddonPayload(player, "RESTORE:AVAILABLE:" + std::to_string(selected->guid));
    SendAddonPayload(player, "WARN:SAVED_TO_DB_RESTORE_AVAILABLE_THIS_SESSION_ONLY");
}

static void HandleRestoreSavedPosition(Player* player)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    SelectedObject* selected = nullptr;
    if (!RequireSelection(player, selected))
        return;

    if (!selected->hasRestore)
    {
        SendAddonPayload(player, "ERROR:NO_RESTORE_POSITION_AVAILABLE");
        return;
    }

    selected->current = selected->restorePosition;

    WorldDatabase.Execute(
        "UPDATE `gameobject` SET `position_x` = {}, `position_y` = {}, `position_z` = {}, `orientation` = {}, `rotation0` = {}, `rotation1` = {}, `rotation2` = {}, `rotation3` = {} WHERE `guid` = {}",
        selected->current.x, selected->current.y, selected->current.z, selected->current.o,
        selected->current.r0, selected->current.r1, selected->current.r2, selected->current.r3, selected->guid);

    selected->lastSaved = selected->current;
    selected->dirty = false;
    selected->undoHistory.clear();
    selected->hasUndo = false;
    selected->hasRestore = false;

    SendAddonPayload(player, BuildSelectedPayload("UPDATED", *selected));
    SendUndoStatus(player, *selected);
    SendAddonPayload(player, "RESTORED:" + std::to_string(selected->guid));
    SendAddonPayload(player, "RESTORE:UNAVAILABLE");
    SpawnSelectionPreview(player, *selected);
}

static void HandleRefreshPreview(Player* player)
{
    if (!HasAccess(player))
    {
        SendAddonPayload(player, GE_ACCESS_DENIED);
        return;
    }

    SelectedObject* selected = nullptr;
    if (!RequireSelection(player, selected))
        return;

    SpawnSelectionPreview(player, *selected);
}

static void DispatchPayload(Player* player, std::string const& payload)
{
    if (payload == GE_ACCESS_REQUEST)
    {
        HandleHello(player);
        return;
    }

    std::vector<std::string> parts = Split(payload, ':');
    if (parts.empty())
        return;

    try
    {
        if (parts[0] == "SCAN")
            HandleScan(player, parts);
        else if (parts[0] == "SEARCH_TEMPLATE")
            HandleSearchTemplate(player, parts);
        else if (parts[0] == "SEARCH_CREATURE_TEMPLATE")
            HandleSearchCreatureTemplate(player, parts);
        else if (parts[0] == "PLACE_TEMPLATE")
            HandlePlaceTemplate(player, parts);
        else if (parts[0] == "PLACE_CREATURE_TEMPLATE")
            HandlePlaceCreatureTemplate(player, parts);
        else if (parts[0] == "DELETE_CREATURE_SELECTED")
            HandleDeleteCreatureSelected(player, parts);
        else if (parts[0] == "PREVIEW_CREATURE_CACHE")
            HandlePreviewCreatureCache(player, parts);
        else if (parts[0] == "NUDGE_CREATURE")
            HandleNudgeCreature(player, parts);
        else if (parts[0] == "ROTATE_CREATURE")
            HandleRotateCreature(player, parts);
        else if (parts[0] == "UNDO_CREATURE")
            HandleUndoCreature(player, parts);
        else if (parts[0] == "SAVE_CREATURE")
            HandleSaveCreature(player, parts);
        else if (parts[0] == "RESTORE_CREATURE_POSITION")
            HandleRestoreCreaturePosition(player, parts);
        else if (parts[0] == "RESET_CREATURE_TO_ORIGINAL")
            HandleResetCreatureToOriginal(player, parts);
        else if (parts[0] == "DELETE_SELECTED")
            HandleDeleteSelected(player, parts);
        else if (parts[0] == "SELECT")
            HandleSelect(player, parts);
        else if (parts[0] == "NUDGE")
            HandleNudge(player, parts);
        else if (parts[0] == "ROTATE")
            HandleRotate(player, parts);
        else if (parts[0] == "FACE_ME")
            HandleFaceMe(player);
        else if (parts[0] == "UNDO")
            HandleUndo(player);
        else if (parts[0] == "RESET_TO_ORIGINAL")
            HandleResetToOriginal(player);
        else if (parts[0] == "SAVE")
            HandleSave(player);
        else if (parts[0] == "RESTORE_SAVED_POSITION")
            HandleRestoreSavedPosition(player);
        else if (parts[0] == "REFRESH_PREVIEW" || parts[0] == "FLASH")
            HandleRefreshPreview(player);
        else if (parts[0] == "CLEAR")
            ClearEditorSession(player);
        else
            SendAddonPayload(player, "ERROR:UNKNOWN_OPCODE:" + parts[0]);
    }
    catch (std::exception const& ex)
    {
        SendAddonPayload(player, std::string("ERROR:EXCEPTION:") + ex.what());
    }
}

class gobject_editor_player_script : public PlayerScript
{
public:
    gobject_editor_player_script() : PlayerScript("gobject_editor_player_script") { }

    void OnPlayerBeforeSendChatMessage(Player* player, uint32& /*type*/, uint32& lang, std::string& msg) override
    {
        if (lang != LANG_ADDON)
            return;

        std::string payload;
        if (!ParsePrefixedAddonMessage(msg, payload))
            return;

        if (IsDebugEnabled())
            LOG_INFO("module", "mod-gobject-editor received GE payload from {}: {}", player ? player->GetName() : "unknown", payload);

        DispatchPayload(player, payload);
    }

    void OnPlayerLogout(Player* player) override
    {
        if (!player)
            return;

        ClearEditorSession(player);
    }
};
} // namespace

void Addmod_gobject_editorScripts()
{
    new gobject_editor_player_script();
}
