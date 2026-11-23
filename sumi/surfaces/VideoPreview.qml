import QtQuick
import QtMultimedia

/**
 * Muted, looping preview of a video wallpaper. Lives in its own file so
 * QtMultimedia is only pulled into the process the first time a video tile is
 * actually previewed — an inline component would load the module as soon as
 * the wallpaper surface compiles, whether or not any video is ever focused.
 */
Item {
    id: root
    property string path: ""

    VideoOutput {
        id: out
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        visible: player.playbackState === MediaPlayer.PlayingState
    }

    MediaPlayer {
        id: player
        videoOutput: out
        source: root.path.length > 0 ? "file://" + root.path : ""
        loops: MediaPlayer.Infinite
        audioOutput: null
        onMediaStatusChanged: if (mediaStatus === MediaPlayer.LoadedMedia) play()
    }
}
