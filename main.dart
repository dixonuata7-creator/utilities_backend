import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:io'; 
import 'dart:convert'; 
import 'package:flutter/foundation.dart';
import 'dart:typed_data'; 
import 'package:file_selector/file_selector.dart';
import 'package:exif/exif.dart' show Rational, IfdTag, readExifFromBytes;
import 'package:xml/xml.dart'; 
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Galaxify Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const DashboardScreen(),
    );
  }
}

// =========================================================================
// DATA MODELS 
//=========================================================================

class PhotoExifData {
  final String dateTaken;
  final String cameraModel;
  final String focalLength;
  final double? latitude; 
  final double? longitude; 
  final double? altitude; 
  final Map<String, String> otherTags; 

  PhotoExifData({
    required this.dateTaken,
    required this.cameraModel,
    required this.focalLength,
    this.latitude,
    this.longitude,
    this.altitude,
    required this.otherTags,
  });
}

class PhotoAsset {
  final String fileName;
  final String folder;
  final String fileKind; 
  final PhotoExifData exif;

  PhotoAsset({
    required this.fileName,
    required this.folder,
    required this.fileKind, 
    required this.exif,
  });
}

class Detection {
  final String className;
  final double score;

  Detection(this.className, double score) : score = score.clamp(0.0, 1.0); 
}

class KpiGroup {
  final String className;
  final Map<String, int> scoreRanges; 

  KpiGroup(this.className) : scoreRanges = {'0-20%': 0, '20-49%': 0, '50-79%': 0, '80-100%': 0};

  int getTotal() => scoreRanges.values.fold(0, (sum, count) => sum + count);
}


// =========================================================================
// EXIF EXTRACTION AND GPS CONVERSION LOGIC
// =========================================================================

double _rationalToDouble(dynamic rational) {
  if (rational != null && rational.numerator != null && rational.denominator != null) {
    if (rational.denominator != 0) {
      return (rational.numerator as num) / (rational.denominator as num);
    }
  }
  try {
    return (rational as num).toDouble();
  } catch (_) {
    return 0.0;
  }
}

double? _convertGpsToDecimal(dynamic values, String ref) {
  if (values is List && values.length == 3) {
    try {
      final degrees = _rationalToDouble(values[0]); 
      final minutes = _rationalToDouble(values[1]);
      final seconds = _rationalToDouble(values[2]);

      double decimal = degrees + (minutes / 60) + (seconds / 3600);
      
      if (decimal == 0.0) return null;

      if (ref == 'S' || ref == 'W') {
        decimal *= -1;
      }
      return decimal;
    } on Exception catch (e) {
      print('Error parsing GPS values: $e');
      return null;
    }
  }
  return null;
}

Future<PhotoExifData> _extractExifData(XFile file) async {
  try {
    final bytes = await file.readAsBytes();
    final Map<String, IfdTag> data = await readExifFromBytes(bytes);

    if (data.isEmpty) {
      return PhotoExifData(
        dateTaken: 'N/A (No EXIF)', cameraModel: 'N/A', focalLength: 'N/A', otherTags: {},
      );
    }
    
    String _cleanString(String s) {
        String cleaned = s.trim();
        if (cleaned.length >= 2 && 
            (cleaned.startsWith('"') && cleaned.endsWith('"') || 
             cleaned.startsWith("'") && cleaned.endsWith("'"))
        ) {
          cleaned = cleaned.substring(1, cleaned.length - 1).trim();
        }
        return cleaned.replaceAll('\u0000', '').trim();
    }

    String getTagValue(String key) {
      final tag = data[key];
      if (tag == null) {
        return 'N/A';
      }
      if (key == 'DateTimeOriginal') {
        return tag.printable.replaceAll(':', '-');
      }
      return _cleanString(tag.printable);
    }
    
    // ** FIX: Extended list of explicitly handled keys **
    const List<String> allExplicitKeys = [
      'DateTimeOriginal', 'Model', 'CameraModelName', 'Make', 'FocalLength', 
      'GPSLatitude', 'GPSLongitude', 'GPSAltitude', 'GPSLatitudeRef', 'GPSLongitudeRef', 'GPSAltitudeRef',
      'ImageDescription', 'ExifVersion',
      'ImageModel',         
      'GPS GPSLatitude',    
      'GPS GPSLongitude',   
      'GPS GPSLatitudeRef',  
      'GPS GPSLongitudeRef', 
    ];

    final Map<String, String> otherPrintableTags = {};
    
    data.forEach((key, tag) {
        // Use the extended list of keys
        if (!allExplicitKeys.contains(key)) { 
            final printableValue = _cleanString(tag.printable);
            if (printableValue.isNotEmpty && 
                !printableValue.startsWith('IfdTag') && 
                printableValue != 'N/A') 
            {
                otherPrintableTags[key] = printableValue;
            }
        }
    });

    final dateString = getTagValue('DateTimeOriginal');
    final focal = getTagValue('FocalLength');
    
    // Model tags
    final model = getTagValue('Model');
    final cameraName = getTagValue('CameraModelName'); 
    final make = getTagValue('Make');

    String cameraDescription;
    if (model != 'N/A' && model.isNotEmpty) {
      cameraDescription = model;
    } else if (cameraName != 'N/A' && cameraName.isNotEmpty) {
      cameraDescription = cameraName;
    } else if (make != 'N/A' && make.isNotEmpty) {
      cameraDescription = make;
    } else {
      final imageModelTag = data['ImageModel'];
      if (imageModelTag != null) {
         cameraDescription = _cleanString(imageModelTag.printable);
      } else {
         cameraDescription = 'N/A';
      }
    }

    double? latitude;
    double? longitude;
    double? altitude;

    // 1. Check for standard GPS tags
    dynamic latTag = data['GPSLatitude'];
    dynamic lonTag = data['GPSLongitude'];

    // 2. Fallback to user-specified GPS tags if standard ones are missing
    if (latTag == null) {
        latTag = data['GPS GPSLatitude']; 
    }
    if (lonTag == null) {
        lonTag = data['GPS GPSLongitude'];
    }

    // --- CRITICAL FIX: Robust GPS Reference Tag Retrieval ---
    // Latitude Reference Logic
    String latRef = 'N'; // Default to North
    if (data['GPSLatitudeRef'] != null && getTagValue('GPSLatitudeRef') != 'N/A') {
        latRef = getTagValue('GPSLatitudeRef');
    } else if (data['GPS GPSLatitudeRef'] != null && getTagValue('GPS GPSLatitudeRef') != 'N/A') { 
        // Check non-standard reference tag
        latRef = getTagValue('GPS GPSLatitudeRef');
    }
    latRef = latRef.toUpperCase();

    // Longitude Reference Logic
    String lonRef = 'E'; // Default to East
    if (data['GPSLongitudeRef'] != null && getTagValue('GPSLongitudeRef') != 'N/A') {
        lonRef = getTagValue('GPSLongitudeRef');
    } else if (data['GPS GPSLongitudeRef'] != null && getTagValue('GPS GPSLongitudeRef') != 'N/A') { 
        // Check non-standard reference tag
        lonRef = getTagValue('GPS GPSLongitudeRef');
    }
    lonRef = lonRef.toUpperCase();
    // --------------------------------------------------------

    final altTag = data['GPSAltitude']; 

    // Now, attempt conversion if coordinate tags are present
    if (latTag != null && lonTag != null) {
      
      final cleanedLatRef = latRef;
      final cleanedLonRef = lonRef;

      if ((cleanedLatRef == 'N' || cleanedLatRef == 'S') && (cleanedLonRef == 'E' || cleanedLonRef == 'W')) {
        // Attempt conversion assuming the tag holds the expected structure (List of Rational objects)
        if (latTag.values != null && lonTag.values != null) {
            latitude = _convertGpsToDecimal(latTag.values.toList(), cleanedLatRef);
            longitude = _convertGpsToDecimal(lonTag.values.toList(), cleanedLonRef);
        }
      }
      
      if (altTag != null && data['GPSAltitudeRef'] != null) {
          try {
              final altValues = altTag.values.toList();
              altitude = _rationalToDouble(altValues[0]);
              
              if (data['GPSAltitudeRef']!.printable.trim() == '1') {
                  altitude = -altitude;
              }
          } catch (e) {
              print('Error parsing GPS Altitude: $e');
              altitude = null;
          }
      }
    } 
    
    return PhotoExifData(
      dateTaken: dateString.length > 19 ? dateString.substring(0, 19) : dateString,
      cameraModel: cameraDescription,
      focalLength: focal,
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      otherTags: otherPrintableTags,
    );

  } catch (e) {
    print('Error processing file ${file.name}: $e');
    return PhotoExifData(
      dateTaken: 'Error Reading File', cameraModel: 'N/A', focalLength: 'N/A', otherTags: {},
    );
  }
}

// =========================================================================
// MOCK AWS S3 INTEGRATION 
//=========================================================================

// Mock S3 credentials
const String _AWS_ACCESS_KEY_ID = "AKIAX56SX7KRHNDGNGR3";
const String _AWS_SECRET_ACCESS_KEY = "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";
const String _BUCKET_NAME = "gnutilities";
const String _SCAN_FOLDER = "/output/images";

/// **SIMULATED** S3 scan function
/// 
/// **NOTE:** This function simulates the network request and file scanning 
/// that would be performed by a real AWS SDK for Dart/Flutter. 
/// A real implementation would require an AWS SDK package and a secure 
/// connection mechanism.
List<PhotoAsset> _mockS3Scan(String folderPath) {
  // Credentials and folder are used here conceptually, but this is mock data.
  // In a real app, this would involve a network call to AWS SDK 
  // (e.g., S3 client.listObjects(bucketName, prefix: folderPath)).
  if (folderPath == _SCAN_FOLDER) {
    final syncTime = DateTime.now().toLocal().toString().substring(0, 19);
    final folderPathDisplay = 's3://${_BUCKET_NAME}${_SCAN_FOLDER}';

    return [
      PhotoAsset(
        fileName: 'S3_METER_004.jpeg',
        folder: folderPathDisplay,
        fileKind: 'JPEG',
        exif: PhotoExifData(
          dateTaken: '2024-06-01 15:00',
          cameraModel: 'Cloud_Camera_v1',
          focalLength: '10.0mm',
          latitude: -34.615, 
          longitude: -58.370,
          altitude: 18.0,
          otherTags: {'Source': 'S3 Cloud', 'SyncTime': syncTime, 'AWS Key ID': _AWS_ACCESS_KEY_ID},
        ),
      ),
      PhotoAsset(
        fileName: 'S3_CABINET_005.jpg',
        folder: folderPathDisplay,
        fileKind: 'JPG',
        exif: PhotoExifData(
          dateTaken: '2024-06-02 09:12',
          cameraModel: 'Cloud_Camera_v2',
          focalLength: '8.0mm',
          // No location for this one
          latitude: null, 
          longitude: null,
          altitude: 20.0,
          otherTags: {'Source': 'S3 Cloud', 'SyncTime': syncTime, 'AWS Key ID': _AWS_ACCESS_KEY_ID},
        ),
      ),
    ];
  }
  return [];
}

// =========================================================================
// UI COMPONENTS 
// =========================================================================

/// Custom Marker Widget that displays metadata on hover.
class LocationMarkerWithHover extends StatefulWidget {
  final PhotoAsset asset;
  const LocationMarkerWithHover({super.key, required this.asset});

  @override
  State<LocationMarkerWithHover> createState() => _LocationMarkerWithHoverState();
}

class _LocationMarkerWithHoverState extends State<LocationMarkerWithHover> {
  bool _isHovering = false;

  /// Enhanced placeholder to be more visible and dynamic.
  Widget _getAssetImagePlaceholder() {
    // Simulate image content based on the file name for visual distinction
    final bool isMeter = widget.asset.fileName.toLowerCase().contains('meter');
    
    final Color iconColor = isMeter ? Colors.lightGreenAccent : Colors.amberAccent;
    final IconData iconData = isMeter ? Icons.electric_meter : Icons.photo;

    // We use a prominent icon as a placeholder for the small image due to environment limitations.
    // In a real app, this would be a NetworkImage or FileImage loaded asynchronously.
    return Container(
      width: 60, // Larger size for visibility
      height: 60, 
      decoration: BoxDecoration(
        color: const Color(0xFF38006b).lighten(20), // Darker background for contrast
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white70, width: 1.0)
      ),
      child: Icon(iconData, color: iconColor, size: 30),
    );
  }

  Widget _buildHoverCard() {
    return Positioned(
      bottom: 60, // Increased position to accommodate the larger card
      child: Card(
        color: const Color(0xFF510099),
        elevation: 10, // Higher elevation for prominence
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Colors.white54, width: 0.5)
        ),
        child: Container(
          width: 200, // Slightly wider card
          padding: const EdgeInsets.all(10.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. Placeholder image (simulating small picture) - Now larger and centered
              Center(child: _getAssetImagePlaceholder()), 
              const Divider(color: Colors.white54, height: 10),
              // 2. Name
              Text(
                widget.asset.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
              ),
              // 3. Date taken
              Text(
                'Date: ${widget.asset.exif.dateTaken.split(' ')[0]}', // Show only date
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // MouseRegion detects hover events
    return MouseRegion(
      onEnter: (event) => setState(() => _isHovering = true),
      onExit: (event) => setState(() => _isHovering = false),
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          // The main marker icon
          const Icon(
            Icons.camera_alt,
            color: Colors.red,
            size: 40.0,
          ),
          // The hover card, visible only when hovering
          if (_isHovering) _buildHoverCard(),
        ],
      ),
    );
  }
}

// Rest of the UI Components...

Widget _buildDetailRow(String label, String value, {Color? valueColor, FontWeight fontWeight = FontWeight.bold}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130, 
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.black54, fontSize: 13),
              overflow: TextOverflow.ellipsis, 
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor ?? Colors.black87, fontWeight: fontWeight, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

Widget _buildAssetDetailsTile(PhotoAsset asset) {
  final hasLocation = asset.exif.latitude != null && asset.exif.longitude != null;
  final locationColor = hasLocation ? Colors.green.shade700 : Colors.red.shade700;

  return Card(
    margin: const EdgeInsets.only(bottom: 12),
    elevation: 2,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    child: Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            asset.fileName,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF510099)),
          ),
          const Divider(),
          _buildDetailRow('Kind', asset.fileKind),
          _buildDetailRow('Source/Folder', asset.folder),
          _buildDetailRow('Date Taken', asset.exif.dateTaken),
          _buildDetailRow('Camera Model', asset.exif.cameraModel),
          _buildDetailRow('Focal Length', asset.exif.focalLength),
          _buildDetailRow('Latitude', asset.exif.latitude != null ? asset.exif.latitude!.toStringAsFixed(6) : 'N/A', 
            valueColor: locationColor),
          _buildDetailRow('Longitude', asset.exif.longitude != null ? asset.exif.longitude!.toStringAsFixed(6) : 'N/A', 
            valueColor: locationColor),
          _buildDetailRow('Altitude', asset.exif.altitude != null ? '${asset.exif.altitude!.toStringAsFixed(1)} m' : 'N/A'),

          if (asset.exif.otherTags.isNotEmpty) ...[
            const SizedBox(height: 15),
            const Text(
              '--- All Other EXIF Tags ---',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
            const Divider(height: 10),
            ...asset.exif.otherTags.entries.map((entry) {
              return _buildDetailRow(entry.key, entry.value, valueColor: Colors.black54, fontWeight: FontWeight.normal);
            }).toList(),
          ] else if (asset.exif.dateTaken != 'Error Reading File') ...[
               const SizedBox(height: 10),
               const Text('No additional EXIF data found beyond core properties.', 
                   style: TextStyle(fontSize: 13, color: Colors.black54)),
          ]
        ],
      ),
    ),
  );
}

class SingleAssetDetailsDialog extends StatelessWidget {
  final PhotoAsset asset;

  const SingleAssetDetailsDialog({super.key, required this.asset});

  @override
  Widget build(BuildContext context) {
    // --- RESIZE FIX: Increased content width from 500.0 to 750.0 ---
    const double contentWidth = 750.0; 

    return AlertDialog(
      title: Text(
        'Details: ${asset.fileName}', 
        style: const TextStyle(color: Color(0xFF510099), fontWeight: FontWeight.bold),
      ),
      backgroundColor: Colors.white,
      content: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        width: contentWidth, 
        child: Scrollbar(
          thumbVisibility: true,
          child: SingleChildScrollView(
            child: _buildAssetDetailsTile(asset), 
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: const Text('Close', style: TextStyle(color: Colors.black54)),
          onPressed: () {
            Navigator.of(context).pop(); 
          },
        ),
      ],
    );
  }
}

class UploadConfirmationDialog extends StatelessWidget {
  final List<PhotoAsset> assets;

  const UploadConfirmationDialog({super.key, required this.assets});
  
  @override
  Widget build(BuildContext context) {
    // --- RESIZE FIX: Increased content width from 500.0 to 750.0 ---
    const double contentWidth = 750.0; 

    return AlertDialog(
      title: Text(
        'Confirm Upload (${assets.length} file${assets.length > 1 ? 's' : ''})', 
        style: const TextStyle(color: Color(0xFF510099), fontWeight: FontWeight.bold),
      ),
      backgroundColor: Colors.white,
      content: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        width: contentWidth, 
        child: Scrollbar(
          thumbVisibility: true,
          child: ListView.builder(
            itemCount: assets.length,
            itemBuilder: (context, index) {
              final asset = assets[index];
              return _buildAssetDetailsTile(asset); 
            },
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: const Text('Cancel', style: TextStyle(color: Colors.red)),
          onPressed: () {
            Navigator.of(context).pop(false); 
          },
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.lightGreen),
          child: const Text('Confirm & Add', style: TextStyle(color: Colors.black)),
          onPressed: () {
            Navigator.of(context).pop(true);
            
          },
        ),
      ],
    );
  }
}

// =========================================================================
// DASHBOARD SCREEN (MAIN LAYOUT)
// =========================================================================

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _selectedMenu = 'dashboard';
  // **MODIFIED:** Use a list to hold multiple selected PhotoAsset objects
  List<PhotoAsset> _selectedAssetsOnMap = []; 
  final LatLng _argentinaCenter = const LatLng(-34.6037, -58.3816);
  final List<Map<String, dynamic>> _menuItems = [
    {'name': 'dashboard', 'icon': Icons.dashboard, 'tooltip': 'Asset Details'},
    {'name': 'list', 'icon': Icons.list_alt, 'tooltip': 'Photo Properties Table (Maximize)'},
    {'name': 'kpi', 'icon': Icons.score, 'tooltip': 'Detection KPIs'},
    {'name': 'settings', 'icon': Icons.settings, 'tooltip': 'Settings'},
  ];

  // **MODIFIED:** Handle a list of PhotoAsset objects selected from the table
  void _handleLocationSelected(List<PhotoAsset> assets) {
    setState(() {
      // Filter to only include assets with location data
      _selectedAssetsOnMap = assets
          .where((asset) => asset.exif.latitude != null && asset.exif.longitude != null)
          .toList();
      
      // Switch to the map view if locations are selected from the list view
      if (_selectedAssetsOnMap.isNotEmpty && _selectedMenu == 'list') {
         _selectedMenu = 'dashboard';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    bool isTableMaximized = _selectedMenu == 'list' || _selectedMenu == 'kpi';

    return Scaffold(
      body: Row(
        children: [
          _buildNavBar(),
          _buildInfoPanel(isTableMaximized),
          if (!isTableMaximized) _buildMapArea(),
        ],
      ),
    );
  }

  Widget _buildSidebarIcon(IconData icon, String name, String tooltip) {
    bool isSelected = _selectedMenu == name;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedMenu = name;
            // Clear selected locations when switching away from the map view
            if (name != 'dashboard') {
              _selectedAssetsOnMap = [];
            }
          });
        },
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
          padding: const EdgeInsets.all(8.0),
          decoration: isSelected
              ? BoxDecoration(
                  color: const Color(0xFF6A00C8), 
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Icon(
            icon,
            color: Colors.white.withOpacity(isSelected ? 1.0 : 0.7),
            size: 24,
          ),
        ),
      ),
    );
  }

  Widget _buildNavBar() {
    return Container(
      width: 60, 
      color: const Color(0xFF38006b), 
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: const Icon(
              Icons.settings_system_daydream, 
              color: Colors.white, 
              size: 30,
            ),
          ),
          const SizedBox(height: 20),
          ..._menuItems.map((item) => _buildSidebarIcon(
                item['icon'],
                item['name'] as String,
                item['tooltip'] as String,
              )),
          const Spacer(),
          _buildSidebarIcon(Icons.arrow_back, 'logout', 'Logout'),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _getPanelContent() {
    switch (_selectedMenu) {
      case 'dashboard':
        return const AssetDetailsPanel(
          selectedMeterId: "EM441115-88",
        );
      case 'list':
        return PhotoPropertiesTable(
          // Pass the updated callback
          onLocationsSelected: _handleLocationSelected,
        );
      case 'kpi': 
        return const KpiDashboardPanel();
      default:
        return const Center(child: Text("Content for this menu is not implemented.", style: TextStyle(color: Colors.white70)));
    }
  }

  Widget _buildInfoPanel(bool isMaximized) {
    return isMaximized
        ? Expanded(
            child: Container(
              color: const Color(0xFF510099), 
              child: _getPanelContent(), 
            ),
          )
        : Container(
            width: 320, 
            color: const Color(0xFF510099), 
            child: _getPanelContent(), 
            );
  }

  Widget _buildMapArea() {
    // **MODIFIED:** Center the map on the first selected asset's location
    final LatLng center = _selectedAssetsOnMap.isNotEmpty 
        ? LatLng(_selectedAssetsOnMap.first.exif.latitude!, _selectedAssetsOnMap.first.exif.longitude!) 
        : _argentinaCenter;

    return Expanded(
      child: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: center,
              // Adjust zoom level if multiple locations are selected
              initialZoom: _selectedAssetsOnMap.length > 1 ? 8.0 : (_selectedAssetsOnMap.isNotEmpty ? 14.0 : 10.0), 
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.app',
              ),
              // Build a MarkerLayer for all selected locations
              if (_selectedAssetsOnMap.isNotEmpty)
                MarkerLayer(
                  markers: _selectedAssetsOnMap.map((asset) => Marker(
                      width: 100.0,
                      height: 100.0,
                      // Use the asset's coordinates
                      point: LatLng(asset.exif.latitude!, asset.exif.longitude!),
                      // **MODIFIED:** Use the custom marker widget
                      child: LocationMarkerWithHover(asset: asset),
                    ),
                  ).toList(),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------------
// 1. ASSET DETAILS PANEL (UNCHANGED)
// -------------------------------------------------------------------------

class AssetDetailsPanel extends StatefulWidget {
  final String selectedMeterId;
  const AssetDetailsPanel({super.key, required this.selectedMeterId});

  @override
  State<AssetDetailsPanel> createState() => _AssetDetailsPanelState();
}

class _AssetDetailsPanelState extends State<AssetDetailsPanel> {
  bool _isInfoMinimized = false;
  bool _isStatusMinimized = false;
  bool _isPhotosMinimized = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Electric Meter: AM1120308475',
                style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 13),
              ),
              const Icon(Icons.close, color: Colors.white70),
            ],
          ),
        ),
        const Divider(color: Colors.white54, height: 1),
        Expanded(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader(
                    'Information',
                    Icons.info,
                    isMinimized: _isInfoMinimized,
                    onToggle: () {
                      setState(() {
                        _isInfoMinimized = !_isInfoMinimized;
                      });
                    },
                  ),
                  if (!_isInfoMinimized) ...[
                    _buildInfoRow('ID', widget.selectedMeterId),
                    _buildInfoRow('Category', 'Electric Meter'),
                    _buildInfoRow('Address', '72 Bold Hill Dr, Webster, NY'),
                    const SizedBox(height: 20),
                  ],

                  _buildSectionHeader(
                    'Status',
                    Icons.bar_chart,
                    isMinimized: _isStatusMinimized,
                    onToggle: () {
                      setState(() {
                        _isStatusMinimized = !_isStatusMinimized;
                      });
                    },
                  ),
                  if (!_isStatusMinimized) ...[
                    _buildInfoRow('User name', 'Steve Smith'),
                    _buildInfoRow('Work order number', 'WOH4822'),
                    const SizedBox(height: 10),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFB76D0E), 
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Missing',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  _buildSectionHeader(
                    'Photos',
                    Icons.image,
                    count: 2,
                    isMinimized: _isPhotosMinimized,
                    onToggle: () {
                      setState(() {
                        _isPhotosMinimized = !_isPhotosMinimized;
                      });
                    },
                  ),
                  if (!_isPhotosMinimized) ...[
                    _buildPhotoCard(
                      Icons.electric_meter,
                      'Detection: Electric Meter\nType: D10 meter\nConfidence: 1',
                    ),
                    _buildPhotoCard(
                      Icons.offline_bolt,
                      'Detection: Old meter\nType: D10 meter\nConfidence: 1',
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(
    String title,
    IconData icon, {
    int? count,
    required bool isMinimized,
    required VoidCallback onToggle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (count != null)
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Text(
                '$count',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 14,
                ),
              ),
            ),
          const Spacer(),
          IconButton(
            icon: Icon(
              isMinimized ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: Colors.white70,
            ),
            onPressed: onToggle,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100, 
            child: Text(
              '$label:',
              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoCard(IconData icon, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10.0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(
          color: const Color(0xFF6A00C8), 
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: Colors.deepPurple.shade900, 
              ),
              child: Icon(icon, color: Colors.lightGreenAccent, size: 30),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                description,
                style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------------
// 2. PHOTO PROPERTIES TABLE (UPDATED)
// -------------------------------------------------------------------------

class PhotoPropertiesTable extends StatefulWidget {
  // **MODIFIED:** Callback now takes a list of PhotoAsset objects
  final Function(List<PhotoAsset> assets) onLocationsSelected;

  const PhotoPropertiesTable({super.key, required this.onLocationsSelected});

  @override
  State<PhotoPropertiesTable> createState() => _PhotoPropertiesTableState();
}

class _PhotoPropertiesTableState extends State<PhotoPropertiesTable> {
  
  // State to hold currently selected assets for map display
  final Set<PhotoAsset> _selectedAssets = {}; 
  bool _isProcessingFiles = false; // Flag for both local and cloud file operations
  String _operationStatus = ''; // Status message for the current operation

  final List<PhotoAsset> _mockAssets = [
    PhotoAsset(
      fileName: 'METER_001.jpg',
      folder: 'Site_A',
      fileKind: 'JPG', 
      exif: PhotoExifData(
        dateTaken: '2024-05-15 10:30',
        cameraModel: 'iPhone 15',
        focalLength: '4.2mm',
        latitude: -34.609,
        longitude: -58.379,
        altitude: 25.0,
        otherTags: {},
      ),
    ),
    PhotoAsset(
      fileName: 'METER_002.jpg',
      folder: 'Site_A',
      fileKind: 'JPG', 
      exif: PhotoExifData(
        dateTaken: '2024-05-15 10:31',
        cameraModel: 'Samsung S22',
        focalLength: '5.1mm',
        // This one has no location
        latitude: null,
        longitude: null,
        altitude: null,
        otherTags: {},
      ),
    ),
    PhotoAsset(
      fileName: 'METER_003.jpg',
      folder: 'Site_B',
      fileKind: 'JPG', 
      exif: PhotoExifData(
        dateTaken: '2024-05-16 11:45',
        cameraModel: 'GoPro Hero 11',
        focalLength: '2.5mm',
        latitude: -34.580,
        longitude: -58.450,
        altitude: 32.0,
        otherTags: {},
      ),
    ),
  ];
  
  void _showAssetDetailsDialog(PhotoAsset asset) {
    showDialog(
      context: context,
      builder: (context) {
        return SingleAssetDetailsDialog(asset: asset); 
      },
    );
  }
  
  void _showSelectedOnMap() {
    // **MODIFIED:** Pass the full list of selected assets to the callback
    widget.onLocationsSelected(_selectedAssets.toList());
  }

  void _onSelectionChanged(bool? isSelected, PhotoAsset asset) {
    // Only allow selection if the asset has location data
    if (asset.exif.latitude == null || asset.exif.longitude == null) {
      return; 
    }
    setState(() {
      if (isSelected == true) {
        _selectedAssets.add(asset);
      } else {
        _selectedAssets.remove(asset);
      }
    });
  }

  Future<void> _selectLocalImages(BuildContext context) async {
    
    const XTypeGroup typeGroup = XTypeGroup(
      label: 'images',
      extensions: <String>['jpg', 'jpeg', 'png', 'tiff'],
    );
    
    final List<XFile> files = await openFiles( 
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
      initialDirectory: null, 
      confirmButtonText: 'Select Images',
    );

    if (files.isEmpty) {
      setState(() {
         _operationStatus = 'Local image selection canceled.';
      });
      return; 
    }

    setState(() {
      _isProcessingFiles = true;
      _operationStatus = 'Processing ${files.length} local files...';
    });

    final List<PhotoAsset> processedAssets = [];
    
    for (final XFile file in files) {
      final exifData = await _extractExifData(file);
      final fileNameParts = file.name.split('.');
      final fileKind = fileNameParts.length > 1 ? fileNameParts.last.toUpperCase() : 'N/A';

      processedAssets.add(PhotoAsset(
        fileName: file.name, 
        folder: 'Local_Upload',
        fileKind: fileKind, 
        exif: exifData,
      ));
    }
    
    setState(() {
      _isProcessingFiles = false; 
    });

    if (processedAssets.isNotEmpty) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) {
          return UploadConfirmationDialog(assets: processedAssets);
        },
      );

      if (confirmed == true) {
        setState(() {
          _mockAssets.insertAll(0, processedAssets); 
          _selectedAssets.clear();
          _operationStatus = '${processedAssets.length} local files added.';
        });
      } else {
         setState(() {
           _operationStatus = 'Local file upload canceled.';
         });
      }
    } else {
      setState(() {
        _operationStatus = 'No valid images selected.';
      });
    }
  }

  /// **NEW:** Function to handle the simulated cloud sync
  Future<void> _syncWithCloud(BuildContext context) async {
      setState(() {
        _isProcessingFiles = true;
        _operationStatus = 'Connecting to S3 bucket: $_BUCKET_NAME...';
      });
      
      // 1. Simulate Connection/Scanning
      // Placeholder for actual AWS SDK calls using the provided credentials
      await Future.delayed(const Duration(seconds: 2)); // Simulate network latency

      setState(() {
         _operationStatus = 'Scanning folder $_SCAN_FOLDER...';
      });
      
      // Simulate the retrieval of mock data
      final List<PhotoAsset> cloudAssets = _mockS3Scan(_SCAN_FOLDER);

      setState(() {
        _isProcessingFiles = false;
      });

      if (cloudAssets.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('S3 Sync Complete: No new files found in /output/images.')),
          );
          setState(() {
             _operationStatus = 'S3 Sync Complete. No new files found.';
          });
          return;
      }

      // 2. Show Confirmation Dialog (like 'Select Local Images')
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) {
          // This presents the new screen/dialog with the S3 file metadata
          return UploadConfirmationDialog(assets: cloudAssets);
        },
      );

      // 3. Update Table if Confirmed
      if (confirmed == true) {
        setState(() {
          // Add assets to the main list
          _mockAssets.insertAll(0, cloudAssets);
          _selectedAssets.clear();
          _operationStatus = '${cloudAssets.length} files added from S3.';
        });
      } else {
         setState(() {
           _operationStatus = 'S3 sync canceled.';
         });
      }
  }


  // UPDATED: Added 'Map' (Checkbox) column
  List<DataColumn> get _columns {
    const style = TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13);
    return const [
        DataColumn(label: Text('Map', style: style)), // New column for checkbox
        DataColumn(label: Text('File Name', style: style)),
        DataColumn(label: Text('Kind', style: style)),
        DataColumn(label: Text('Date Taken', style: style)),
        DataColumn(label: Text('Camera Model', style: style)),
        DataColumn(label: Text('Focal Length', style: style)),
        DataColumn(label: Text('Latitude', style: style)),
        DataColumn(label: Text('Longitude', style: style)),
        DataColumn(label: Text('Altitude (m)', style: style)),
        DataColumn(label: Text('Details', style: style)), 
    ];
  }

  // UPDATED: Implement checkbox and selection logic in DataRow
  List<DataRow> _getRows() {
      
      return _mockAssets.map((asset) {
          final hasLocation = asset.exif.latitude != null && asset.exif.longitude != null;
          // Check if the asset is currently in the selected set
          final isSelected = _selectedAssets.contains(asset);
          final locationColor = hasLocation ? Colors.lightGreenAccent : Colors.redAccent;

          return DataRow(
              // DataRow 'selected' property is used for visual highlighting
              selected: isSelected,
              // DataRow onSelectChanged is set to null to rely solely on the explicit Checkbox for multi-selection
              onSelectChanged: null, 
              cells: [
                  // Checkbox Cell
                  DataCell(
                      Checkbox(
                          value: isSelected,
                          // Only allow changing the checkbox state if the asset has location
                          onChanged: hasLocation ? (isSelected) => _onSelectionChanged(isSelected, asset) : null,
                          activeColor: Colors.lightGreenAccent,
                          checkColor: Colors.black,
                          // Custom colors for disabled state
                          fillColor: MaterialStateProperty.resolveWith<Color>((Set<MaterialState> states) {
                              if (states.contains(MaterialState.disabled)) {
                                  return Colors.grey.shade700;
                              }
                              return Colors.white;
                          }),
                      ),
                  ),
                  DataCell(Text(asset.fileName, style: const TextStyle(fontSize: 13, color: Colors.white))),
                  DataCell(Text(asset.fileKind, style: const TextStyle(fontSize: 13, color: Colors.white))),
                  DataCell(Text(asset.exif.dateTaken, style: const TextStyle(fontSize: 13, color: Colors.white))),
                  DataCell(Text(asset.exif.cameraModel, style: const TextStyle(fontSize: 13, color: Colors.white))),
                  DataCell(Text(asset.exif.focalLength, style: const TextStyle(fontSize: 13, color: Colors.white))),
                  DataCell(Text(asset.exif.latitude != null ? asset.exif.latitude!.toStringAsFixed(4) : 'N/A',
                      style: TextStyle(color: locationColor, fontSize: 13))),
                  DataCell(Text(asset.exif.longitude != null ? asset.exif.longitude!.toStringAsFixed(4) : 'N/A',
                      style: TextStyle(color: locationColor, fontSize: 13))),
                  DataCell(Text(asset.exif.altitude != null ? asset.exif.altitude!.toStringAsFixed(1) : 'N/A',
                      style: const TextStyle(fontSize: 13, color: Colors.white))),
                  DataCell(
                    ElevatedButton(
                      onPressed: () => _showAssetDetailsDialog(asset), 
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6A00C8), 
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero, 
                      ),
                      child: const Text('View Details', style: TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                  ),
              ],
          );
      }).toList();
  }


  @override
  Widget build(BuildContext context) {
    // Find assets that have location data for checking against selection logic
    final List<PhotoAsset> mappableAssets = _mockAssets
        .where((asset) => asset.exif.latitude != null && asset.exif.longitude != null)
        .toList();

    // Check if all mappable assets are selected for the Select All checkbox state
    final bool isAllSelected = _selectedAssets.length == mappableAssets.length && mappableAssets.isNotEmpty;
    
    // Check if the "Show in Map" button should be enabled
    final bool isShowInMapEnabled = _selectedAssets.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Photo Assets',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  
                  // Buttons Group
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // *** NEW: 1. Sync with Cloud button ***
                      ElevatedButton.icon(
                        onPressed: _isProcessingFiles ? null : () => _syncWithCloud(context),
                        icon: _isProcessingFiles && _operationStatus.contains('S3') 
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) 
                            : const Icon(Icons.cloud_sync, size: 18),
                        label: const Text('Sync with Cloud'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepOrange, // Distinct color
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade600,
                          disabledForegroundColor: Colors.grey.shade400,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 2. Show in Map button
                      ElevatedButton.icon(
                        onPressed: isShowInMapEnabled ? _showSelectedOnMap : null, 
                        icon: const Icon(Icons.map, size: 18),
                        label: const Text('Show in Map'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade600,
                          disabledForegroundColor: Colors.grey.shade400,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 3. Select Local Images button
                      ElevatedButton.icon(
                        // Disable button while processing
                        onPressed: _isProcessingFiles ? null : () => _selectLocalImages(context),
                        icon: _isProcessingFiles && _operationStatus.contains('local')
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black)) 
                            : const Icon(Icons.folder_open, size: 18),
                        label: const Text('Select Local Images'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.lightGreen, 
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              // Status text for operations
              if (_operationStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    _operationStatus,
                    style: TextStyle(
                      color: _operationStatus.contains('Error') || _operationStatus.contains('canceled') ? Colors.redAccent : Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(color: Colors.white54, height: 1),
        
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical, 
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal, 
              child: DataTable(
                headingRowColor: MaterialStateProperty.all(const Color(0xFF6A00C8)),
                dataRowColor: MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
                  return const Color(0xFF510099); 
                }),
                onSelectAll: mappableAssets.isNotEmpty 
                    ? (isSelected) {
                        setState(() {
                          if (isSelected == true) {
                            _selectedAssets.addAll(mappableAssets);
                          } else {
                            _selectedAssets.clear();
                          }
                        });
                      }
                    : null,
                columns: _columns,
                rows: _getRows(), 
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------------
// 5. KPI DASHBOARD PANEL (UNCHANGED)
// -------------------------------------------------------------------------

class KpiDashboardPanel extends StatefulWidget {
  const KpiDashboardPanel({super.key});

  @override
  State<KpiDashboardPanel> createState() => _KpiDashboardPanelState();
}

// =========================================================================
// TOP-LEVEL/STATIC HELPER FUNCTIONS FOR ISOLATES (UNCHANGED)
// =========================================================================

String _getRangeKey(double score) {
  score = score.clamp(0.0, 1.0);
  
  if (score >= 0.0 && score <= 0.20) return '0-20%';
  if (score > 0.20 && score <= 0.49) return '20-49%';
  if (score > 0.49 && score <= 0.79) return '50-79%';
  if (score > 0.79 && score <= 1.0) return '80-100%';
  return 'N/A';
}

List<Detection> _parseDetectionContent(String content, String extension) {
  final detections = <Detection>[];
  try {
    if (extension == 'json') {
      final List<dynamic> jsonList = jsonDecode(content);

      for (var item in jsonList) {
        if (item is Map<String, dynamic> && item.containsKey('class_name') && item.containsKey('score')) {
          final className = item['class_name'] as String;
          double score = (item['score'] is int) ? (item['score'] as int).toDouble() : item['score'] as double;
          if (score > 1.0 && score <= 100.0) score /= 100.0;
          
          detections.add(Detection(className, score));
        }
      }
    } else if (extension == 'xml') { 
      final document = XmlDocument.parse(content);
      final detectionElements = document.findAllElements('detection');

      for (var element in detectionElements) {
        final classNameElement = element.findElements('class_name').firstOrNull;
        final scoreElement = element.findElements('score').firstOrNull;

        if (classNameElement != null && scoreElement != null) {
          final className = classNameElement.innerText.trim();
          final scoreText = scoreElement.innerText.trim();
          
          if (double.tryParse(scoreText) case double score) {
            if (score > 1.0 && score <= 100.0) score /= 100.0;
            
            detections.add(Detection(className, score));
          }
        }
      }
    }
    
  } catch (_) {
  }
  return detections;
}

List<KpiGroup> _aggregateDetectionsInIsolate(List<Detection> allDetections) {
  final Map<String, KpiGroup> kpiMap = {};
  
  for (var detection in allDetections) {
    final className = detection.className;
    final rangeKey = _getRangeKey(detection.score);

    kpiMap.putIfAbsent(className, () => KpiGroup(className));
    
    final currentCount = kpiMap[className]!.scoreRanges[rangeKey] ?? 0;
    kpiMap[className]!.scoreRanges[rangeKey] = currentCount + 1;
  }
  
  return kpiMap.values.toList()..sort((a, b) => b.getTotal().compareTo(a.getTotal()));
}

// =========================================================================
// PDF GENERATION LOGIC (UNCHANGED)
// =========================================================================

/// Helper to build a single KPI group for the PDF
pw.Widget _buildPdfKpiGroup(KpiGroup group) {
  // Define colors for visual consistency in the PDF
  final Map<String, PdfColor> colors = {
    '80-100%': PdfColors.green700,
    '50-79%': PdfColors.yellow700,
    '20-49%': PdfColors.orange700,
    '0-20%': PdfColors.red700,
  };

  return pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 15),
    padding: const pw.EdgeInsets.all(10),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.deepPurple700, width: 1),
      borderRadius: pw.BorderRadius.circular(5),
      // Manually calculated lighter purple color (0xFF8033DC).
      color: PdfColor.fromInt(0xFF8033DC), 
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Object Type: ${group.className}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13, color: PdfColors.white)),
            pw.Text('Total Detections: ${group.getTotal()}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13, color: PdfColors.lightGreenAccent)),
          ],
        ),
        pw.Divider(color: PdfColors.white, thickness: 0.5),
        ...group.scoreRanges.entries.map((entry) {
          final range = entry.key;
          final count = entry.value;
          final fraction = group.getTotal() > 0 ? count / group.getTotal() : 0.0;
          final barColor = colors[range] ?? PdfColors.grey;

          return pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3.0),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('$count detections in range $range', style: const pw.TextStyle(fontSize: 10, color: PdfColors.white)),
                    pw.Text('${(fraction * 100).toStringAsFixed(1)}%', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: barColor)),
                  ],
                ),
                pw.SizedBox(height: 2),
                // Bar visualization
                pw.Container(
                  height: 6,
                  decoration: pw.BoxDecoration(color: PdfColors.grey200, borderRadius: pw.BorderRadius.circular(3)),
                  child: pw.Container(
                    width: fraction.clamp(0.0, 1.0) * double.infinity, 
                    decoration: pw.BoxDecoration(color: barColor, borderRadius: pw.BorderRadius.circular(3)),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ],
    ),
  );
}

/// Generates the PDF document bytes from the KPI results.
Future<Uint8List> _generateKpiReportPdf(List<KpiGroup> results, String info) async {
  final pdf = pw.Document();

  // FIX: Switched from pw.Page to pw.MultiPage to enable content flow across pages.
  pdf.addPage(
    pw.MultiPage( 
      pageFormat: PdfPageFormat.a4,
      build: (pw.Context context) {
        // MultiPage build function must return a List<pw.Widget> that flows.
        return [
            // Fixed Header Content (Wrapped in Column)
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Header(
                  level: 0,
                  child: pw.Text('Detection KPI Report', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 24, color: PdfColor.fromInt(0xFF510099))),
                ),
                pw.Text('Report Date: ${DateTime.now().toLocal().toString().substring(0, 19)}'),
                pw.SizedBox(height: 5),
                pw.Text('Source: $info', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                pw.Divider(), 
                pw.SizedBox(height: 10),
                pw.Text(
                    'Object Type vs. Confidence Score Distribution',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 15),
                ),
                pw.SizedBox(height: 10),
              ],
            ),
            // Dynamic, Flowing Content (KPI Groups)
            // This list of widgets will flow automatically to the next page if needed.
            ...results.map((group) => _buildPdfKpiGroup(group)), 
        ];
      },
    ),
  );

  return pdf.save();
}

// =========================================================================
// STATE CLASS IMPLEMENTATION (UNCHANGED)
// =========================================================================

class _KpiDashboardPanelState extends State<KpiDashboardPanel> {
  String _selectionInfo = 'No files selected.'; 
  List<XFile> _selectedKpiFiles = [];
  bool _isScanning = false;
  List<KpiGroup> _kpiResults = [];
  
  // NEW: Function to handle PDF generation and saving
  Future<void> _generateAndSavePdf() async {
    if (_kpiResults.isEmpty) return;

    // Use scanning state for loading indicator
    setState(() {
      _isScanning = true; 
    });

    try {
      // 1. Generate the PDF document bytes
      final Uint8List pdfBytes = await _generateKpiReportPdf(_kpiResults, _selectionInfo);
      
      // 2. Define the suggested file name
      final String timestamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);
      final String fileName = 'KPI_Report_$timestamp.pdf';
      
      // 3. Prompt the user to save the file using file_selector's saveFile
      final XFile kpiFile = XFile.fromData(pdfBytes, mimeType: 'application/pdf', name: fileName);
      
      // FIX: saveTo returns Future<void>, so we just await the call.
      await kpiFile.saveTo(fileName);

      // 4. Update the UI to confirm success
      setState(() {
        _isScanning = false;
        _selectionInfo = 'Report saved successfully as $fileName!';
      });

    } catch (e) {
      // Catch exceptions, which include cases where the user cancels the dialog on some platforms
      // and general file system errors.
      if (e.toString().contains('User cancelled')) {
         setState(() {
          _isScanning = false;
          _selectionInfo = 'PDF generation canceled by user.';
        });
      } else {
         setState(() {
          _isScanning = false;
          _selectionInfo = 'Error saving PDF: $e';
        });
      }
    }
  }


  Future<void> _pickFiles() async {
    const XTypeGroup typeGroup = XTypeGroup(
      label: 'Detection Files (JSON/XML)',
      extensions: <String>['json', 'xml'],
    );
    
    final List<XFile> files = await openFiles( 
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
      initialDirectory: null, 
      confirmButtonText: 'Select Detection Files',
    );
    
    if (files.isNotEmpty) {
      setState(() {
        _selectedKpiFiles = files;
        _selectionInfo = '${files.length} file${files.length > 1 ? 's' : ''} selected.';
        _kpiResults = [];
      });
    } else {
      setState(() {
         _selectionInfo = 'No files selected.';
         _selectedKpiFiles = [];
         _kpiResults = [];
      });
    }
  }

  Future<List<Detection>> _processSingleXFile(XFile file) async {
    try {
      final content = await file.readAsString(); 
      final extension = file.name.split('.').last.toLowerCase();
      return _parseDetectionContent(content, extension); 
    } catch (e) {
      print('Error processing file ${file.name}: $e');
      return []; 
    }
  }

  Future<void> _processSelectedKpiFiles() async {
    if (_selectedKpiFiles.isEmpty) {
        setState(() {
           _selectionInfo = 'Error: Please select detection files first.';
        });
        return;
    }

    setState(() {
      _isScanning = true;
      _kpiResults = [];
    });

    try {
      final processingTasks = _selectedKpiFiles.map((file) => _processSingleXFile(file)).toList();
      final List<List<Detection>> results = await Future.wait(processingTasks);
      final allDetections = results.expand((list) => list).toList();
      
      final aggregatedResults = await compute(_aggregateDetectionsInIsolate, allDetections);

      setState(() {
        _kpiResults = aggregatedResults;
        _isScanning = false;
        if (_kpiResults.isEmpty) {
           _selectionInfo = 'Scan complete. No valid detection data found in the selected files.';
        }
      });

    } catch (e) {
      setState(() {
        _isScanning = false;
        _selectionInfo = 'Error: Failed to process files: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Check if there are results to print
    final bool hasKpiResults = _kpiResults.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Detection KPI Dashboard',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6A00C8), 
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _selectionInfo,
                        style: TextStyle(
                            color: _selectionInfo.startsWith('Error:') ? Colors.redAccent : Colors.white, 
                            fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: _isScanning ? null : _pickFiles,
                    icon: const Icon(Icons.file_open, size: 18),
                    label: const Text('Select Files'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent, 
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Center( 
                 child: Row(
                   mainAxisAlignment: MainAxisAlignment.center,
                   children: [
                      // Process Button
                      ElevatedButton.icon(
                          onPressed: (_isScanning || _selectedKpiFiles.isEmpty) 
                                     ? null 
                                     : _processSelectedKpiFiles,
                          icon: _isScanning 
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black)) 
                              : const Icon(Icons.analytics, size: 18),
                          label: Text(_isScanning ? 'Processing...' : 'Process Selected Files'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.lightGreen, 
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10) 
                          ),
                      ),
                      const SizedBox(width: 15),
                      // NEW: Print PDF Button
                      ElevatedButton.icon(
                          onPressed: (_isScanning || !hasKpiResults) 
                                     ? null 
                                     : _generateAndSavePdf,
                          icon: Icon(Icons.print, size: 18, color: hasKpiResults ? Colors.white : Colors.grey.shade400),
                          label: Text('Save PDF Report', style: TextStyle(color: hasKpiResults ? Colors.white : Colors.grey.shade400)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF510099).lighten(10), // A slightly different purple
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10) 
                          ),
                      ),
                   ],
                 ),
              ),
            ],
          ),
        ),
        const Divider(color: Colors.white54, height: 1),
        
        Expanded(
          child: _buildResultsView(),
        ),
      ],
    );
  }

  Widget _buildResultsView() {
    if (_isScanning) {
      return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 10),
              Text('Processing files and aggregating data...', style: TextStyle(color: Colors.white70)),
            ],
          )
      );
    }

    if (_selectedKpiFiles.isEmpty && !_selectionInfo.startsWith('Error:')) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.analytics_outlined, color: Colors.white54, size: 50),
                SizedBox(height: 10),
                Text(
                  'Please select detection files (.json or .xml) to analyze, then press "Process Selected Files".', 
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ],
            ),
          )
        );
    }
    
    if (_selectionInfo.startsWith('Error:')) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 50),
                const SizedBox(height: 10),
                Text(
                  _selectionInfo, 
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 14),
                ),
              ],
            ),
          )
        );
    }
    
    if (_kpiResults.isEmpty) {
        return Center(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(
                _selectionInfo,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            )
        );
    }
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Object Type vs. Confidence Score Distribution',
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          Text(
            'Analyzed detections from: $_selectionInfo',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 10),
          ..._kpiResults.map((group) => _buildKpiGroupCard(group)).toList(),
        ],
      ),
    );
  }

  Widget _buildKpiGroupCard(KpiGroup group) {
    return Card(
      color: const Color(0xFF6A00C8), 
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Object Type: ${group.className}',
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Total Detections: ${group.getTotal()}',
                  style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(color: Colors.white30),
            ...group.scoreRanges.entries.map((entry) {
              final range = entry.key;
              final count = entry.value;
              
              double fraction = group.getTotal() > 0 ? count / group.getTotal() : 0.0;
              Color barColor;
              if (range.contains('80')) barColor = Colors.greenAccent;
              else if (range.contains('50')) barColor = Colors.yellowAccent;
              else if (range.contains('20')) barColor = Colors.orangeAccent;
              else barColor = Colors.redAccent;
              
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('$count detections in range $range', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        Text('${(fraction * 100).toStringAsFixed(1)}%', style: TextStyle(color: barColor, fontSize: 12, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: fraction,
                        backgroundColor: Colors.white10,
                        valueColor: AlwaysStoppedAnimation<Color>(barColor),
                        minHeight: 8,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ],
        ),
      ),
    );
  }
}

// Utility to lighten a color (for the button)
extension on Color {
  Color lighten(int amount) {
    final int r = (red + amount).clamp(0, 255);
    final int g = (green + amount).clamp(0, 255);
    final int b = (blue + amount).clamp(0, 255);
    return Color.fromARGB(alpha, r, g, b);
  }
}